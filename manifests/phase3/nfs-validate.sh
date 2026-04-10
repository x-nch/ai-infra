#!/bin/bash
# nfs-validate.sh - Run from any node to test NFS connectivity

NFS_SERVER="${NFS_SERVER:-192.168.1.101}"
NFS_PATH="${NFS_PATH:-/mnt/nfs/share}"
LOCAL_MOUNT="${LOCAL_MOUNT:-/tmp/nfs-test}"

echo "=== Testing NFS Connectivity ==="
echo "NFS Server: $NFS_SERVER"
echo "NFS Path: $NFS_PATH"

# Create local mount point
mkdir -p $LOCAL_MOUNT

# Show available exports
echo ""
echo "Checking NFS exports..."
showmount -e $NFS_SERVER

# Mount NFS
echo ""
echo "Mounting NFS..."
mount -t nfs $NFS_SERVER:$NFS_PATH $LOCAL_MOUNT

if [ $? -eq 0 ]; then
  echo "Mount successful!"
  
  # Write test file
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  TESTFILE="$LOCAL_MOUNT/test_$TIMESTAMP.txt"
  HOSTNAME=$(hostname)
  
  echo "NFS test from $HOSTNAME at $TIMESTAMP" > $TESTFILE
  
  # Read back
  echo "Reading test file..."
  cat $TESTFILE
  
  # Cleanup
  rm $TESTFILE
  umount $LOCAL_MOUNT
  
  echo ""
  echo "=== NFS Validation PASSED ==="
  exit 0
else
  echo ""
  echo "=== NFS Validation FAILED ==="
  echo "Troubleshooting:"
  echo "1. Check NFS server is running: systemctl status nfs-server"
  echo "2. Check firewall: showmount -e $NFS_SERVER"
  echo "3. Check mount: mount -t nfs $NFS_SERVER:$NFS_PATH $LOCAL_MOUNT -v"
  exit 1
fi