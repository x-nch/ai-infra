#!/bin/bash
# node-labels.sh - Apply labels to cluster nodes

echo "=== Applying node labels ==="

# Node 1 - RTX 3090 Primary GPU Node
echo "Labeling Node 1 (RTX 3090)..."
kubectl label nodes node1 \
  gpu-type=rtx3090 \
  workload-type=gpu-primary \
  --overwrite

# Node 2 - GTX 1650 Secondary GPU Node
echo "Labeling Node 2 (GTX 1650)..."
kubectl label nodes node2 \
  gpu-type=gtx1650 \
  workload-type=gpu-secondary \
  --overwrite

# Node 3 - Control Plane (CPU only)
echo "Labeling Node 3 (Control Plane)..."
kubectl label nodes node3 \
  workload-type=control-plane \
  --overwrite

echo ""
echo "=== Verifying labels ==="
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU-TYPE:.metadata.labels.gpu-type,WORKLOAD:.metadata.labels.workload-type

echo ""
echo "=== Labeling complete ==="