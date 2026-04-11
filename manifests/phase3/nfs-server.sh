#!/bin/bash
# nfs-server.sh - Run on xnch-core (NFS Server)
# NOTE: This script assumes your 1TB SSD is at /dev/sdb1
# Adjust SSD_DEVICE variable if needed

set -e

echo "=== Setting up NFS Server on xnch-core ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo"
  exit 1
fi

# Configuration - ADJUST THESE FOR YOUR SETUP
SSD_DEVICE="${SSD_DEVICE:-/dev/sdb1}"  # Change if your SSD is different
MOUNT_POINT="/mnt/nfs/share"
FILESYSTEM="ext4"

echo "SSD Device: $SSD_DEVICE"
echo "Mount Point: $MOUNT_POINT"

# Check if device exists
if [ ! -b "$SSD_DEVICE" ]; then
  echo "ERROR: Device $SSD_DEVICE not found!"
  echo "Available devices:"
  lsblk -o NAME,TYPE,SIZE,MOUNTPOINT
  exit 1
fi

# Install NFS server
echo "Installing NFS server..."
apt-get update
apt-get install -y nfs-kernel-server

# Create mount point
echo "Creating mount point..."
mkdir -p $MOUNT_POINT

# Check if already mounted
if mount | grep -q "$MOUNT_POINT"; then
  echo "Mount point already in use, checking..."
  mount | grep "$MOUNT_POINT"
else
  # Add to /etc/fstab for persistence
  if ! grep -q "$MOUNT_POINT" /etc/fstab; then
    echo "Adding to /etc/fstab..."
    echo "$SSD_DEVICE $MOUNT_POINT $FILESYSTEM defaults,nofail 0 2" >> /etc/fstab
  fi
  
  # Mount
  echo "Mounting SSD..."
  mount -a
  
  # Verify mount
  if mount | grep -q "$MOUNT_POINT"; then
    echo "Mount successful!"
  else
    echo "ERROR: Mount failed!"
    exit 1
  fi
fi

# Set permissions
chmod -R 777 $MOUNT_POINT
chown nobody:nogroup $MOUNT_POINT

# Configure /etc/exports
echo "Configuring NFS exports..."
cat > /etc/exports << EOF
$MOUNT_POINT *(rw,sync,no_subtree_check,no_root_squash,no_all_squash,insecure)
EOF

# Export
echo "Exporting NFS share..."
exportfs -ra

# Enable and start NFS
echo "Starting NFS server..."
systemctl enable nfs-server
systemctl restart nfs-server

# Verify
echo ""
echo "=== NFS Server Status ==="
systemctl status nfs-server --no-pager
echo ""
echo "Available exports:"
showmount -e localhost

echo ""
echo "=== NFS Share Ready ==="
echo "Export: $MOUNT_POINT"
echo ""
echo "Run on other nodes to mount:"
echo "  mount -t nfs 192.168.1.10:$MOUNT_POINT /mnt/nfs"
echo ""
echo "Or add to /etc/fstab for persistence:"
echo "  192.168.1.10:$MOUNT_POINT /mnt/nfs nfs defaults,_netdev 0 0"