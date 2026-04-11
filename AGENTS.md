# AGENTS.md - NEXI v0 Infrastructure

NEXI v0 — Local-first distributed AI system. **Stack**: Podman + Ollama + Qdrant + OpenZiti.

**This is infrastructure-as-code repo**, not application code. Most changes are config or docs about the physical cluster.

---

## Topology

| Node | IP | Hardware | Services |
|------|-----|----------|---------|
| gate7 | 192.168.1.8 | i7 + GTX 1650 (4GB) | OpenZiti Controller, Qdrant |
| Core | 192.168.1.10 | i9 + RTX 3090 (24GB) | Ollama, NFS |

---

## Fresh Setup (gate7)

SSH to gate7 and run:

```bash
# 1. Stop any existing controller
pkill -f "ziti controller" 2>/dev/null; sleep 2

# 2. Delete old DB (fresh start)
rm -f ~/.ziti/quickstart/gate7/db/ctrl.db

# 3. Source env and start controller
source ~/.ziti/quickstart/gate7/gate7.env
nohup $ZITI_BIN_DIR/ziti controller run ~/.ziti/quickstart/gate7/gate7.yaml > ~/.ziti/gate7-controller.log 2>&1 &
sleep 5

# 4. Initialize edge with admin
export PATH=$ZITI_BIN_DIR:$PATH
ziti controller edge init ~/.ziti/quickstart/gate7/gate7.yaml -u admin -p admin123

# 5. Login
ziti edge login gate7:1280 -u admin -p admin123

# 6. Create Qdrant service
ziti edge create service nexi-qdrant
ziti edge create terminator nexi-qdrant gate7-edge-router tcp:192.168.1.8:6333
ziti edge create service-policy qdrant-dial Dial --service-roles "@nexi-qdrant" --identity-roles "#all"

# 7. Create client identity
ziti edge create identity user xnch-laptop -a "laptop"
ziti edge create enrollment ott xnch-laptop
```

---

## Laptop Setup (macOS)

```bash
# Install ziti-edge-tunnel
curl -sL "https://github.com/openziti/ziti-tunnel-sdk-c/releases/download/v1.11.4/ziti-edge-tunnel-Darwin_arm64.zip" -o /tmp/ziti-edge-tunnel.zip
unzip -o /tmp/ziti-edge-tunnel.zip -d ~/.local/bin/
chmod +x ~/.local/bin/ziti-edge-tunnel

# Run tunneler (requires sudo on macOS - use Finder > Get Info on terminal to allow)
sudo ~/.local/bin/ziti-edge-tunnel run -i xnch-laptop.json
```

**Note**: Ziti Desktop Edge from Mac App Store is easier - just import `xnch-laptop.json`.

---

## Access via OpenZiti

```bash
# Qdrant
curl http://ziti:nexi-qdrant/collections

# Ollama (if running)
curl http://ziti:vllm-svc/api/tags
```

---

## Deployment Order

1. Start OpenZiti on gate7 (fresh setup above)
2. Create Ziti services
3. Deploy Qdrant on gate7: `podman run -d --name qdrant -p 6333:6333 -v qdrant-storage:/qdrant/storage qdrant/qdrant`
4. Deploy Ollama on Core (if needed)
5. Run tunneler on laptop

---

## Reference Files

| File | Purpose |
|------|---------|
| `docs/08-ziti-setup.md` | Full Ziti setup guide |
| `xnch-laptop.json` | Client identity (enrolled) |
| `docs/NEXI-v0-plan.md` | Full infra plan |