# NEXI v0 - OpenZiti Setup Guide

## Topology

| Node | IP | Hardware | Services |
|------|-----|----------|---------|
| gate7 | 192.168.1.8 | i7 + GTX 1650 (4GB) | OpenZiti Controller, Qdrant |
| Core | 192.168.1.10 | i9 + RTX 3090 (24GB) | Ollama, NFS |

---

## Part 1: gate7 (OpenZiti Controller)

### Prerequisites

```bash
# Install Ziti binaries (if not already installed)
wget https://github.com/openziti/ziti/releases/download/v1.6.14/ziti-linux-amd64-1.6.14.tar.gz
tar -xzf ziti-linux-amd64-1.6.14.tar.gz
# Place ziti binary in PATH
```

### Fresh Setup (delete existing DB)

```bash
# SSH to gate7
ssh x-nch@192.168.1.8

# Stop existing controller if running
pkill -f "ziti controller"

# Delete old database (fresh start)
rm -f ~/.ziti/quickstart/gate7/db/ctrl.db

# Source environment
source ~/.ziti/quickstart/gate7/gate7.env

# Start controller in background
nohup $ZITI_BIN_DIR/ziti controller run ~/.ziti/quickstart/gate7/gate7.yaml > ~/.ziti/gate7-controller.log 2>&1 &

# Wait for startup
sleep 5

# Check it's running
pgrep -af "ziti controller"
```

### Initialize Edge with Admin User

```bash
source ~/.ziti/quickstart/gate7/gate7.env
export PATH=$ZITI_BIN_DIR:$PATH

# Initialize edge with admin credentials
ziti controller edge init ~/.ziti/quickstart/gate7/gate7.yaml -u admin -p admin123

# Login
ziti edge login gate7:1280 -u admin -p admin123
```

### Create Services

```bash
# Create Qdrant service (assuming Qdrant runs on 192.168.1.8:6333)
ziti edge create service nexi-qdrant
ziti edge create terminator nexi-qdrant gate7-edge-router tcp:192.168.1.8:6333
ziti edge create service-policy qdrant-dial Dial --service-roles "@nexi-qdrant" --identity-roles "#all"

# Create Ollama service (assuming Ollama runs on 192.168.1.10:11434)
ziti edge create service vllm-svc
ziti edge create terminator vllm-svc gate7-edge-router tcp:192.168.1.10:11434
ziti edge create service-policy vllm-dial Dial --service-roles "@vllm-svc" --identity-roles "#all"
```

### Export Client Identity

```bash
# Create client identity and export JWT
ziti edge create identity user xnch-laptop -a "laptop"
ziti edge create enrollment ott xnch-laptop

# Copy the JWT content to laptop
# JWT will be shown in output - copy to xnch-laptop.jwt on laptop
```

---

## Part 2: Laptop (macOS)

### Install ziti-edge-tunnel

```bash
# Download and install
curl -sL "https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/v1.11.4/ziti-edge-tunnel-Darwin_arm64.zip" -o /tmp/ziti-edge-tunnel.zip
unzip -o /tmp/ziti-edge-tunnel.zip -d ~/.local/bin/
chmod +x ~/.local/bin/ziti-edge-tunnel
```

### Enroll Identity

```bash
# Option 1: Use JWT file
ziti-edge-tunnel add --jwt "$(< xnch-laptop.jwt)" --identity xnch-laptop

# Option 2: Use pre-enrolled identity JSON (xnch-laptop.json)
```

### Run Tunneler

```bash
# Run in background (requires sudo for network routing)
sudo ziti-edge-tunnel run -i xnch-laptop.json

# Or run with specific identity directory
sudo ziti-edge-tunnel run --identity-dir ~/.ziti/identities
```

### Test Connectivity

```bash
# Qdrant
curl http://ziti:nexi-qdrant/collections

# Ollama
curl http://ziti:vllm-svc/api/tags
curl -X POST http://ziti:vllm-svc/api/generate -d '{"model":"llama3","prompt":"Hello"}'
```

---

## Troubleshooting

### Controller not responding
```bash
# Check controller is running on gate7
ssh x-nch@192.168.1.8 'pgrep -af "ziti controller"'

# Check logs
ssh x-nch@192.168.1.8 'tail -30 ~/.ziti/gate7-controller.log'
```

### Tunneler issues
```bash
# Check tunneler status
ziti-edge-tunnel status

# Check logs
tail -f ~/.ziti/edge-tunnel.log
```

### Re-authenticate
```bash
# Delete and re-add identity
sudo ziti-edge-tunnel remove --identity xnch-laptop
ziti-edge-tunnel add --jwt "$(< xnch-laptop.jwt)" --identity xnch-laptop
```