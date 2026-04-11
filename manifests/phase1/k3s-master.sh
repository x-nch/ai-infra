#!/bin/bash
# k3s-master.sh - Run on gate7 (k3s Master)
set -e

echo "=== Installing k3s Master on gate7 ==="

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

echo ""
echo "=== Installation Complete ==="
echo "Next steps:"
echo "1. Copy the node token above"
echo "2. Run k3s-agent.sh on xnch-core"
echo "3. Verify all nodes: kubectl get nodes"