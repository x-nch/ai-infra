#!/bin/bash
# k3s-agent.sh - Run on worker nodes
# Usage: ./k3s-agent.sh <MASTER_IP> <NODE_TOKEN>

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <MASTER_IP> <NODE_TOKEN>"
  echo "Example: $0 192.168.1.8 'K10a...'"
  echo ""
  echo "Get MASTER_IP and NODE_TOKEN from k3s-master.sh output"
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

echo ""
echo "=== Worker node joined successfully ==="
echo "Verify on master: kubectl get nodes"