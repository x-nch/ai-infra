#!/bin/bash
# node-labels.sh - Apply labels to cluster nodes

echo "=== Applying node labels ==="

# xnch-core - RTX 3090 Primary GPU Node + NFS Server
echo "Labeling xnch-core (RTX 3090)..."
kubectl label nodes xnch-core \
  gpu-type=rtx3090 \
  workload-type=gpu-primary \
  --overwrite

# gate7 - GTX 1650 GPU Node + Control Plane
echo "Labeling gate7 (GTX 1650 + Control Plane)..."
kubectl label nodes gate7 \
  gpu-type=gtx1650 \
  workload-type=control-plane \
  --overwrite

echo ""
echo "=== Verifying labels ==="
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU-TYPE:.metadata.labels.gpu-type,WORKLOAD:.metadata.labels.workload-type

echo ""
echo "=== Labeling complete ==="