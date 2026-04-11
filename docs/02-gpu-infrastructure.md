# Phase 2: GPU Infrastructure

**Duration**: 1-2 hours | **Severity**: Contains 1 Blocker

---

## Overview

This phase installs the NVIDIA GPU Operator to expose GPUs to Kubernetes and configures node labels for proper GPU workload scheduling.

## Prerequisites

- k3s cluster running (Phase 1 complete)
- NVIDIA drivers installed on GPU nodes (gate7 and xnch-core)

---

## T2.1: GPU Operator Installation

**Blocker**: Host has nvidia-driver-535 installed. GPU Operator default mode will conflict. Must disable Operator driver management.

```bash
# GPU Operator helm install with driver disabled
cat > manifests/phase2/gpu-operator.yml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: gpu-operator
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: gpu-operator
  namespace: gpu-operator
spec:
  chart: nvidia-device-plugin
  repo: https://nvidia.github.io/gpu-operator
  version: 24.6.0
  set:
    driver.enabled: "false"
    toolkit.enabled: "true"
    operator.defaultRuntime: containerd
---
apiVersion: v1
kind: Namespace
metadata:
  name: gpu-operator-resources
---
# Alternative: Direct helm install (recommended)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gpu-operator
  namespace: gpu-operator
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gpu-operator
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: ["apps"]
  resources: ["daemonsets", "deployments"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: ["security.openshift.io"]
  resources: ["securitycontextconstraints"]
  verbs: ["get", "list", "watch", "update", "create"]
- apiGroups: ["security.openshift.io"]
  resources: ["securitycontextconstraints"]
  resourceNames: ["privileged"]
  verbs: ["use"]
- apiGroups: ["config.openshift.io"]
  resources: ["clusteroperators"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["config.openshift.io"]
  resources: ["clusteroperators"]
  verbs: ["get", "list", "watch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gpu-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: gpu-operator
subjects:
- kind: ServiceAccount
  name: gpu-operator
  namespace: gpu-operator
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nvidia-gpu-operator
  namespace: gpu-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nvidia-gpu-operator
  template:
    metadata:
      labels:
        app: nvidia-gpu-operator
    spec:
      serviceAccountName: gpu-operator
      containers:
      - name: gpu-operator
        image: nvcr.io/nvidia/gpu-operator:v24.6.0
        args:
        - --config-controller-path=/etc/gpu-operator-config
        - --controller-runtime-service-account=gpu-operator
        command:
        - gpu-operator
        env:
        - name: WITH_WORKBENCH
          value: "false"
        - name: CLUSTER_POLICY_NAME
          value: gpu-operator-cluster-policy
        - name: OPERATOR_CONTAINER_IMAGE
          value: nvcr.io/nvidia/gpu-operator:v24.6.0
        - name: TOOLKIT_CONTAINER_IMAGE
          value: nvcr.io/nvidia/k8s/container-toolkit:v1.14.1
        - name: DEVICE_PLUGIN_CONTAINER_IMAGE
          value: nvcr.io/nvidia/k8s/device-plugin:v0.14.6
        - name: DRIVER_CONTAINER_IMAGE
          value: nvcr.io/nvidia/driver:535.129.03-ubuntu22.04
        - name: NODE_STATUS_FEATURE
          value: "true"
        - name: MIG_MANAGER_ENABLED
          value: "false"
        - name: OPENSHIFT_VERSION
          value: "4.14"
        - name: GPU_OPERATOR_VERSION
          value: v24.6.0
        securityContext:
          runAsUser: 0
        volumeMounts:
        - name: operator-conig
          mountPath: /etc/gpu-operator-config
      volumes:
      - name: operator-conig
        configMap:
          name: gpu-operator-config
          optional: true
```

### Recommended: Direct Helm Install

```bash
# Add NVIDIA helm repository
helm repo add nvidia https://nvidia.github.io/gpu-operator
helm repo update

# Install GPU Operator with driver disabled
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=true \
  --set operator.defaultRuntime=containerd

# Or create a values file
cat > manifests/phase2/gpu-values.yml << 'EOF'
driver:
  enabled: false
toolkit:
  enabled: true
operator:
  defaultRuntime: containerd
nodeSelector:
  gpu-feature: present
EOF

helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  -f manifests/phase2/gpu-values.yml
```

### Verify Installation

```bash
# Check GPU Operator pods
kubectl get pods -n gpu-operator

# Verify nvidia-smi on nodes
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'

# Expected output should show GPU count per node
# xnch-core   1
# gate7   1
```

---

## T2.2: Node Labeling

Remove redundant nvidia.com/gpu.product labels (set by NFD automatically). Keep only custom gpu-type labels for scheduling affinity.

```bash
# Corrected node labeling script
cat > manifests/phase2/node-labels.yml << 'EOF'
# xnch-core - RTX 3090 Primary GPU Node + NFS Server
kubectl label nodes xnch-core \
  gpu-type=rtx3090 \
  workload-type=gpu-primary \
  --overwrite

# gate7 - GTX 1650 GPU Node + Control Plane
kubectl label nodes gate7 \
  gpu-type=gtx1650 \
  workload-type=control-plane \
  --overwrite
EOF

# Execute
chmod +x manifests/phase2/node-labels.sh
./manifests/phase2/node-labels.sh

# Verify labels
kubectl get nodes --show-labels | grep -E "gpu-type|workload-type"
```

> **Important**: Do NOT set `nvidia.com/gpu.product` manually - it's auto-managed by GPU Operator's Node Feature Discovery (NFD).

---

## T2.3: GPU Validation Pod

Test pod that runs nvidia-smi, confirms GPU scheduling on both nodes independently.

```bash
# GPU validation job manifest
cat > manifests/phase2/gpu-test.yml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: gpu-validation-rtx3090
  namespace: default
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        app: gpu-test
    spec:
      restartPolicy: Never
      nodeSelector:
        gpu-type: rtx3090
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: cuda-test
        image: nvidia/cuda:12.0.0-base-ubuntu22.04
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "=== Testing RTX 3090 GPU ==="
            nvidia-smi
            echo "=== GPU Test Passed ==="
        resources:
          limits:
            nvidia.com/gpu: 1
          requests:
            nvidia.com/gpu: 1
---
apiVersion: batch/v1
kind: Job
metadata:
  name: gpu-validation-gtx1650
  namespace: default
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        app: gpu-test
    spec:
      restartPolicy: Never
      nodeSelector:
        gpu-type: gtx1650
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: cuda-test
        image: nvidia/cuda:12.0.0-base-ubuntu22.04
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "=== Testing GTX 1650 GPU ==="
            nvidia-smi
            echo "=== GPU Test Passed ==="
        resources:
          limits:
            nvidia.com/gpu: 1
          requests:
            nvidia.com/gpu: 1
EOF

# Apply and verify
kubectl apply -f manifests/phase2/gpu-test.yml

# Watch job completion
kubectl get jobs -w
kubectl logs job/gpu-validation-rtx3090
kubectl logs job/gpu-validation-gtx1650

# Expected output should show GPU info for each card
# If successful, cleanup:
kubectl delete -f manifests/phase2/gpu-test.yml
```

### Expected Output (RTX 3090)

```
=== Testing RTX 3090 GPU ===
Thu Apr  9 12:00:00 UTC 2026
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 535.129.03   Driver Version: 535.129.03   CUDA Version: 12.2     |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf  Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
|===============================+======================+======================|
|   0  NVIDIA GeForce ...  Off  | 00000000:01:00.0 Off |                  N/A |
|  0%   42C    P8    17W / 350W |      1MiB / 24564MiB |      0%      Default |
+-------------------------------+----------------------+----------------------+
=== GPU Test Passed ===
```

---

## Validation Commands

```bash
# Verify GPU Operator installed
kubectl get pods -n gpu-operator

# Check GPU resource allocation
kubectl describe nodes | grep -A 5 "nvidia.com/gpu"

# Verify node labels
kubectl get nodes -l gpu-type=rtx3090
kubectl get nodes -l gpu-type=gtx1650

# Check GPU scheduling
kubectl get pods -o wide | grep nvidia
```

---

## Troubleshooting

### GPU Not Showing

```bash
# Check NFD pod status
kubectl get pods -n gpu-operator-resources

# Check nvidia-device-plugin DaemonSet
kubectl get ds -n gpu-operator-resources

# Restart nvidia-device-plugin
kubectl rollout restart ds/nvidia-device-plugin -n gpu-operator-resources
```

### Driver Conflict

```bash
# Verify host driver version
nvidia-smi

# Check if driver is loaded in container
kubectl exec -it <pod-name> -- nvidia-smi
```

---

## Next Phase

Proceed to [Phase 3: Storage + KubeRay](./03-storage-kuberay.md)