# Phase 3: Storage + KubeRay

**Duration**: 1-2 hours | **Severity**: Contains 1 Blocker + 1 Fix

---

## Overview

This phase sets up shared NFS storage for model weights and datasets, and installs the KubeRay operator to manage Ray clusters on Kubernetes.

## Prerequisites

- k3s cluster running (Phase 1 complete)
- GPU Operator installed (Phase 2 complete)
- 1TB SSD connected to Node 1

---

## T3.1: NFS Server Setup

Install NFS server on Node 1 with 1TB SSD mounted.

```bash
#!/bin/bash
# nfs-server.sh - Run on Node 1 (NFS Server)
set -e

echo "=== Setting up NFS Server on Node 1 ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo"
  exit 1
fi

# Get the mount point for your 1TB SSD
# Adjust /dev/sdb1 to your actual device
SSD_DEVICE="/dev/sdb1"
MOUNT_POINT="/mnt/nfs/share"

echo "Installing NFS server..."
apt-get update
apt-get install -y nfs-kernel-server

# Create mount point
mkdir -p $MOUNT_POINT

# Add to /etc/fstab for persistence
if ! grep -q "$MOUNT_POINT" /etc/fstab; then
  echo "$SSD_DEVICE $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# Mount if not already mounted
mount -a

# Set permissions
chmod -R 777 $MOUNT_POINT

# Configure /etc/exports
echo "$MOUNT_POINT *(rw,sync,no_subtree_check,no_root_squash,no_all_squash)" > /etc/exports

# Export
exportfs -ra

# Enable and start NFS
systemctl enable nfs-server
systemctl start nfs-server

# Verify
echo "=== NFS Server Status ==="
systemctl status nfs-server
showmount -e localhost

echo ""
echo "=== NFS Share Ready ==="
echo "Export: $MOUNT_POINT"
echo "Run on other nodes: mount -t nfs 192.168.1.101:$MOUNT_POINT /mnt/nfs"
```

### Execute on Node 1

```bash
chmod +x manifests/phase3/nfs-server.sh
sudo ./manifests/phase3/nfs-server.sh
```

---

## T3.2: NFS Client Setup + PV/PVC

**Blocker**: Original PV missing accessModes. PVC requests 500Gi but PV is 1Ti — static binding will fail.

```bash
# Install NFS client on all nodes
# Run on Node 2 and Node 3:
sudo apt-get install -y nfs-common
```

### Corrected PV + PVC Manifest

```bash
cat > manifests/phase3/pv-pvc.yml << 'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv
  labels:
    type: nfs
    storage-tier: shared
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  mountOptions:
    - hard
    - timeo=600
    - intr
  nfs:
    server: 192.168.1.101
    path: /mnt/nfs/share
    readOnly: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-storage
  namespace: ray-system
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Ti
  storageClassName: ""
  selector:
    matchLabels:
      type: nfs
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: checkpoint-storage
  namespace: ray-training
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 500Gi
  storageClassName: ""
  selector:
    matchLabels:
      type: nfs
EOF

# Apply
kubectl apply -f manifests/phase3/pv-pvc.yml

# Verify
kubectl get pv
kubectl get pvc -n ray-system
```

> **Note**: PVC size must be <= PV size. Both set to 1Ti for consistency.

---

## T3.3: NFS Connectivity Validation

```bash
#!/bin/bash
# nfs-validate.sh - Run from any node to test NFS connectivity

NFS_SERVER="192.168.1.101"
NFS_PATH="/mnt/nfs/share"
LOCAL_MOUNT="/tmp/nfs-test"

echo "=== Testing NFS Connectivity ==="

# Create local mount point
mkdir -p $LOCAL_MOUNT

# Show available exports
echo "Checking NFS exports..."
showmount -e $NFS_SERVER

# Mount NFS
echo "Mounting NFS..."
mount -t nfs $NFS_SERVER:$NFS_PATH $LOCAL_MOUNT

if [ $? -eq 0 ]; then
  echo "Mount successful!"
  
  # Write test file
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  echo "NFS test from $(hostname) at $TIMESTAMP" > $LOCAL_MOUNT/test_$TIMESTAMP.txt
  
  # Read back
  echo "Reading test file..."
  cat $LOCAL_MOUNT/test_$TIMESTAMP.txt
  
  # Cleanup
  rm $LOCAL_MOUNT/test_$TIMESTAMP.txt
  umount $LOCAL_MOUNT
  
  echo "=== NFS Validation PASSED ==="
else
  echo "=== NFS Validation FAILED ==="
  exit 1
fi
```

---

## T3.4: KubeRay Operator Installation

```bash
# Add KubeRay helm repository
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update

# Install KubeRay operator
cat > manifests/phase3/kuberay.yml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ray-system
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: kuberay-operator
  namespace: ray-system
spec:
  chart: kuberay-operator
  repo: https://ray-project.github.io/kuberay-helm
  version: 1.4.2
  set:
    rbacEnable: "true"
    ingressCreate: "false"
EOF

# Or direct helm install
helm install kuberay-operator kuberay/kuberay-operator \
  --namespace ray-system \
  --create-namespace \
  --version 1.4.2

# Verify
kubectl get pods -n ray-system
kubectl get crd | grep ray
```

---

## T3.5: Minimal RayCluster Smoke Test

Deploy a minimal RayCluster (CPU only) to verify Ray head+worker communication.

```bash
cat > manifests/phase3/raycluster-smoke.yml << 'EOF'
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: smoke-test-cluster
  namespace: ray-system
spec:
  # Head group configuration
  headGroupSpec:
    rayStartParams:
      dashboard-host: "0.0.0.0"
      num-cpus: "4"
      # port for Ray head RPC service
      ray-client-server-port: "10001"
    serviceType: ClusterIP
    template:
      spec:
        containers:
        - name: ray-head
          image: rayproject/ray:2.9.3
          imagePullPolicy: IfNotPresent
          ports:
          - containerPort: 8265
            name: dashboard
          - containerPort: 6379
            name: redis
          - containerPort: 10001
            name: ray-worker
          resources:
            requests:
              cpu: "4"
              memory: "16Gi"
            limits:
              cpu: "4"
              memory: "16Gi"
          volumeMounts: []
        serviceAccountName: default
        # Disable DNS automounting to avoid issues with certain CNI plugins
        dnsPolicy: ClusterFirst

  # Worker group configuration
  workerGroupSpecs:
  - groupName: workers
    replicas: 1
    minReplicas: 0
    maxReplicas: 10
    rayStartParams:
      num-cpus: "4"
    template:
      spec:
        containers:
        - name: ray-worker
          image: rayproject/ray:2.9.3
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: "4"
              memory: "16Gi"
            limits:
              cpu: "4"
              memory: "16Gi"
          volumeMounts: []
        serviceAccountName: default
        dnsPolicy: ClusterFirst

  # Ray version
  rayVersion: "2.9.3"
EOF

# Apply
kubectl apply -f manifests/phase3/raycluster-smoke.yml

# Wait for RayCluster to be ready
kubectl get rayclusters.ray.io -n ray-system -w

# Check Ray dashboard (port-forward)
kubectl port-forward -n ray-system svc/smoke-test-cluster-head-svc 8265:8265

# In another terminal, test Ray:
# ray job submit --address http://localhost:10001 -- python -c "print('Hello from Ray!')"

# Cleanup
kubectl delete -f manifests/phase3/raycluster-smoke.yml
```

---

## Validation Commands

```bash
# Verify NFS
kubectl get pv nfs-pv
kubectl get pvc -n ray-system

# Verify KubeRay
kubectl get pods -n ray-system
kubectl get rayclusters.ray.io -n ray-system

# Verify Ray head can communicate with workers
kubectl exec -it smoke-test-cluster-ray-head-0 -n ray-system -- ray health check
```

---

## Troubleshooting

### NFS Mount Issues

```bash
# Check NFS server
showmount -e 192.168.1.101

# Check firewall
sudo ufw status

# Manual mount test
sudo mount -v -t nfs 192.168.1.101:/mnt/nfs/share /mnt/nfs
```

### KubeRay Installation Failed

```bash
# Check helm release status
helm list -n ray-system

# Check operator logs
kubectl logs -n ray-system -l app.kubernetes.io/name=kuberay-operator

# Reinstall
helm uninstall kuberay-operator -n ray-system
helm install kuberay-operator kuberay/kuberay-operator -n ray-system
```

---

## Next Phase

Proceed to [Phase 4: vLLM + External Access](./04-vllm-external.md)