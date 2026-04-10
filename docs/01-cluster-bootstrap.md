# Phase 1: Cluster Bootstrap

**Duration**: 1-2 hours | **Severity**: 1 Fix (k3d on macOS)

---

## Overview

This phase sets up the Kubernetes cluster using k3d (macOS) or k3s (Linux), and prepares the network infrastructure with MetalLB for load balancing.

## macOS (nexi-edge) Setup

| Task | Command |
|------|---------|
| Install | `brew install colima k3d` |
| Start Docker runtime | `colima start` |
| Create cluster | `k3d cluster create ai-infra` |
| Get kubeconfig | `k3d kubeconfig get ai-infra` |

## Node Network Configuration

| Node | Hostname | IP Address | Role |
|------|----------|------------|------|
| nexi-edge | `nexi-edge` | `k3d` | Control Plane |
| xnch-core | `xnch-core` | `192.168.1.10` | GPU Worker + NFS Server |
| gate7 | `gate7` | `192.168.1.8` | GPU Worker |

---

## T1.1: Node Preparation (Ansible Playbook)

Creates a baseline configuration for all nodes.

```bash
# Generate Ansible playbook for node preparation
cat > manifests/phase1/node-prep.yml << 'EOF'
---
- name: Node Preparation for KubeRay Cluster
  hosts: all
  become: true
  vars:
    admin_user: admin
    ssh_port: 22
    allowed_tcp_ports:
      - 6443  # k3s API server
      - 10250 # kubelet
      - 30000-32767  # NodePort range
    ntp_server: pool.ntp.org

  tasks:
    - name: Create admin user
      user:
        name: "{{ admin_user }}"
        groups: docker
        shell: /bin/bash

    - name: Install Docker
      apt:
        name: docker.io
        state: present
        update_cache: yes

    - name: Enable and start Docker
      systemd:
        name: docker
        enabled: true
        state: started

    - name: Add admin to docker group
      user:
        name: "{{ admin_user }}"
        groups: docker
        append: yes

    - name: Install required packages
      apt:
        name:
          - curl
          - wget
          - git
          - nfs-common
          - chrony
        state: present

    - name: Configure UFW rules
      ufw:
        rule: allow
        port: "{{ item }}"
        proto: tcp
      loop: "{{ allowed_tcp_ports }}"

    - name: Enable UFW
      ufw:
        state: enabled
        policy: deny

    - name: Configure NTP
      template:
        src: chrony.conf.j2
        dest: /etc/chrony/chrony.conf
      notify: Restart chrony

    - name: Disable swap
      command: swapoff -a
      failed_when: false

    - name: Remove swap entries from fstab
      lineinfile:
        path: /etc/fstab
        regexp: '^.*swap.*$'
        state: absent

  handlers:
    - name: Restart chrony
      systemd:
        name: chrony
        state: restarted
```

### Usage

```bash
# Create inventory file
cat > inventory.ini << 'EOF'
[node1]
192.168.1.101

[node2]
192.168.1.102

[node3]
192.168.1.103

[all:vars]
ansible_user=ubuntu
ansible_password=your_password
EOF

# Run playbook
ansible-playbook -i inventory.ini manifests/phase1/node-prep.yml
```

---

## T1.2: k3s Installation Scripts

### Master Node Script (Node 3)

```bash
#!/bin/bash
# k3s-master.sh - Run on Node 3 (k3s Master)
set -e

echo "=== Installing k3s Master on Node 3 ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo"
  exit 1
fi

# Install k3s with disabled traefik and proper kubeconfig permissions
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 600" sh -

# Wait for k3s to be ready
echo "Waiting for k3s to be ready..."
sleep 10

# Verify installation
echo "=== k3s Master Status ==="
kubectl get nodes
kubectl get pods -A

# Get node token for worker nodes
echo ""
echo "=== Node Token (save for worker nodes) ==="
cat /var/lib/rancher/k3s/server/node-token

# Get kubeconfig
echo ""
echo "=== kubeconfig location ==="
echo "/etc/rancher/k3s/k3s.yaml"
echo "Copy this to your local machine as ~/.kube/config"
```

### Agent Node Script (Nodes 1 & 2)

```bash
#!/bin/bash
# k3s-agent.sh - Run on Node 1 and Node 2
# Usage: ./k3s-agent.sh <MASTER_IP> <NODE_TOKEN>

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <MASTER_IP> <NODE_TOKEN>"
  echo "Example: $0 192.168.1.103 K10a..."
  exit 1
fi

MASTER_IP=$1
NODE_TOKEN=$2

echo "=== Joining k3s cluster as worker node ==="
echo "Master: $MASTER_IP"

# Install k3s agent
curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_IP}:6443 K3S_TOKEN=${NODE_TOKEN} sh -

# Wait and verify
sleep 10
echo "=== Worker Node Status ==="
kubectl get nodes

echo "Worker node joined successfully!"
```

### Execution

```bash
# On Node 3 (Master)
chmod +x manifests/phase1/k3s-master.sh
sudo ./k3s-master.sh

# Copy the node token output, then on Node 1 and Node 2:
chmod +x manifests/phase1/k3s-agent.sh
sudo ./k3s-agent.sh 192.168.1.103 "K10a..."

# Verify from master
kubectl get nodes -o wide
```

---

## T1.3: MetalLB Configuration (CRITICAL FIX)

**Blocker**: Original plan missing IPAddressPool + L2Advertisement. MetalLB is useless without them.

```bash
# Create MetalLB manifests
cat > manifests/phase1/metallb.yml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: local-pool
      protocol: layer2
      addresses:
      - 192.168.1.200-192.168.1.250  # REPLACE with your available IP range
    ---
    # Layer 2 advertisement (required for layer2 mode)
    l2-advertisement:
      - name: local-advertisement
        address-pool: local-pool
---
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: metallb-system
  name: controller
---
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: metallb-system
  name: speaker
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metallb:controller
rules:
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: [""]
  resources: ["services/status"]
  verbs: ["update"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metallb:controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: metallb:controller
subjects:
- kind: ServiceAccount
  name: controller
  namespace: metallb-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metallb:speaker
rules:
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metallb:speaker
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: metallb:speaker
subjects:
- kind: ServiceAccount
  name: speaker
  namespace: metallb-system
---
# MetalLB Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  namespace: metallb-system
  name: controller
  labels:
    app: metallb
    component: controller
spec:
  replicas: 1
  selector:
    matchLabels:
      app: metallb
      component: controller
  template:
    metadata:
      labels:
        app: metallb
        component: controller
    spec:
      serviceAccountName: controller
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        fsGroup: 65534
      containers:
      - name: controller
        image: registry.k8s.io/metallb/controller:v0.14.5
        args:
        - --controller.namespace=metallb-system
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
        ports:
        - name: monitoring
          containerPort: 7472
        resources:
          limits:
            cpu: 100m
            memory: 100Mi
          requests:
            cpu: 10m
            memory: 20Mi
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  namespace: metallb-system
  name: speaker
  labels:
    app: metallb
    component: speaker
spec:
  selector:
    matchLabels:
      app: metallb
      component: speaker
  template:
    metadata:
      labels:
        app: metallb
        component: speaker
    spec:
      serviceAccountName: speaker
      hostNetwork: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        fsGroup: 65534
      containers:
      - name: speaker
        image: registry.k8s.io/metallb/speaker:v0.14.5
        args:
        - --port=7473
        - --config=config
        - --log-level=info
        env:
        - name: METALLB_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: METALLB_INTERFACE
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        ports:
        - containerPort: 7474
          name: monitoring
        resources:
          limits:
            cpu: 100m
            memory: 100Mi
          requests:
            cpu: 10m
            memory: 20Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
            add:
            - NET_RAW
          readOnlyRootFilesystem: true
```

### Apply MetalLB

```bash
# From k3s master
kubectl apply -f manifests/phase1/metallb.yml

# Verify
kubectl get pods -n metallb-system
```

### Update IP Range

```bash
# Edit the ConfigMap to match your network
kubectl edit configmap config -n metallb-system

# Change addresses to your available range
# Example: 192.168.1.200-192.168.1.250
```

---

## Validation Commands

```bash
# Verify k3s cluster
kubectl get nodes -o wide

# Verify MetalLB
kubectl get pods -n metallb-system
kubectl get configmap config -n metallb-system

# Test MetalLB LoadBalancer
kubectl create deployment test-lb --image=nginx --replicas=1
kubectl expose deployment test-lb --type=LoadBalancer --port=80
kubectl get svc test-lb

# Cleanup test
kubectl delete deployment test-lb
kubectl delete svc test-lb
```

---

## Next Phase

Proceed to [Phase 2: GPU Infrastructure](./02-gpu-infrastructure.md)