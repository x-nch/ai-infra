# AGENTS.md - KubeRay AI Infrastructure

This is an **infrastructure-as-code** repository. There are no traditional build/test/lint commands — the "work" is deploying Kubernetes manifests and running shell scripts on nodes.

---

## Quick Reference

| Task | Command |
|------|---------|
| Deploy phase manifest | `kubectl apply -f manifests/phase<N>/<file>.yml` |
| Run node script | `sudo ./manifests/phase<N>/<script>.sh` |
| Check cluster | `kubectl get nodes -o wide` |
| Check pods | `kubectl get pods -A` |
| Port-forward service | `kubectl port-forward -n <ns> svc/<svc> <local>:<remote>` |

### macOS (nexi-edge) - k3d + Colima

| Task | Command |
|------|---------|
| Install | `brew install colima k3d` |
| Start Docker runtime | `colima start` |
| Create cluster | `k3d cluster create ai-infra` |
| Get kubeconfig | `k3d kubeconfig get ai-infra` |
| Delete cluster | `k3d cluster delete ai-infra` |
| Stop Colima | `colima stop` |

---

## Cluster Topology

- **gate7** (i7, 192.168.1.8): k3s master / control plane + GTX 1650 4GB
- **xnch-core** (i9, 192.168.1.10): RTX 3090 24GB + NFS server (GPU worker)

---

## Critical Port Requirements

- **Port 80**: MUST be reachable for cert-manager HTTP01 TLS challenges
- **Port 31443**: External HTTPS endpoint for vLLM inference

---

## Execution Order (Phase Dependencies)

| Phase | Description | Prerequisites |
|-------|-------------|---------------|
| 1 | Cluster Bootstrap (k3s + MetalLB) | None |
| 2 | GPU Infrastructure | Phase 1 |
| 3 | Storage + KubeRay | Phase 2 |
| 4 | vLLM + External Access | Phase 3 |
| 6 | Monitoring | Phase 4 |

---

## Linting & Validation

### YAML Manifests

```bash
# Dry-run validation (no cluster required)
kubectl apply --dry-run=client -f manifests/phase<N>/<file>.yml

# Full validation against cluster
kubectl apply --dry-run=server -f manifests/phase<N>/<file>.yml

# YAML syntax check with python
python3 -c "import yaml; yaml.safe_load_all(open('manifests/phase<N>/<file>.yml'))"
```

### Shell Scripts

```bash
# Install shellcheck if not present
sudo apt-get install shellcheck

# Lint a shell script
shellcheck manifests/phase<N>/<script>.sh

# Run shellcheck on all scripts
find manifests -name "*.sh" -exec shellcheck {} \;
```

### Python (serve_vllm.py)

```bash
# Install linters
pip install ruff black mypy

# Format code
ruff format manifests/phase4/serve_vllm.py

# Lint code
ruff check manifests/phase4/serve_vllm.py

# Type check
mypy manifests/phase4/serve_vllm.py --ignore-missing-imports
```

---

## Testing

### End-to-End Inference Test

```bash
# Run inference validation script
./manifests/phase4/inference-test.sh

# Test specific components
kubectl logs -n llm-serving -l ray.io/group=worker-group --tail=100
kubectl describe rayservice -n llm-serving
```

### Manual API Testing

```bash
# Health check
curl http://localhost:8000/health

# List models
curl http://localhost:8000/v1/models

# Chat completion (with port-forward)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}'
```

---

## Code Style Guidelines

### YAML (Kubernetes Manifests)

- **Indentation**: 2 spaces (no tabs)
- **Naming**: lowercase with hyphens (e.g., `ray-service`, `vllm-workers`)
- **Resource ordering**: `apiVersion`, `kind`, `metadata`, `spec` (in that order)
- **Labels**: Always include `app` or `component` labels for identification
- **Resources**: Always specify resource requests and limits
- **Comments**: Use `#` for explanatory comments above sections

```yaml
apiVersion: ray.io/v1
kind: RayService
metadata:
  name: vllm-service
  namespace: llm-serving
  labels:
    app: vllm
    component: inference
spec:
  # Comment above logical sections
  rayClusterConfig:
    workerGroupSpecs:
    - groupName: vllm-workers
      replicas: 1
```

### Shell Scripts

- **Shebang**: `#!/bin/bash` (not `#!/bin/sh` unless POSIX-only)
- **Error handling**: `set -e` at the top, use `set -o pipefail` for pipelines
- **Variables**: `UPPER_SNAKE_CASE` for constants, `lowerCamelCase` for locals
- **Functions**: Use `function_name()` syntax (no `function` keyword)
- **Quotes**: Always quote variables (`"$VAR"` not `$VAR`)
- **Exit codes**: Explicit `exit 0` or `exit 1`

```bash
#!/bin/bash
set -e
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/$(basename "$0" .sh).log"

function validate_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        echo "ERROR: kubectl not found" >&2
        return 1
    fi
    return 0
}
```

### Python (serve_vllm.py)

- **Style**: Follow PEP 8
- **Imports**: Standard library, third-party, local (in that order)
- **Type hints**: Use for function parameters and return values
- **Docstrings**: Use triple quotes for module/class/function docs
- **Async**: Use `async/await` for I/O-bound operations

```python
import os
import logging
from typing import Dict, List, Optional

from fastapi import FastAPI, HTTPException, Request
import ray
from ray import serve

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@dataclass
class ChatMessage:
    role: str
    content: str

async def generate(
    prompt: str,
    temperature: float = 0.7,
    max_tokens: int = 512,
) -> Dict:
    """Generate text from prompt using vLLM."""
    ...
```

---

## Error Handling

### Shell Scripts
- Check exit codes: `if command; then ... fi`
- Use `|| true` for optional commands that shouldn't fail
- Redirect errors: `command 2>&1 | tee "$LOG_FILE"`
- Always clean up: Use trap for cleanup on exit

### Python
- Use `try/except` with specific exceptions
- Log errors with appropriate level
- Return meaningful error responses

### YAML/Kubernetes
- Use `readinessProbe` and `livenessProbe` for health checks
- Set appropriate `restartPolicy` and `terminationGracePeriodSeconds`
- Use `imagePullPolicy: IfNotPresent` for stable deployments

---

## Important Notes

1. **MetalLB requires both IPAddressPool AND L2Advertisement** — without L2Advertisement, load balancers won't work
2. **GPU Operator** uses `driver.enabled=false` — host already has nvidia-driver-535
3. **PV/PVC** — ensure accessModes match between static PV and PVC (500Gi vs 1Ti can cause binding failures)
4. **API key auth** is hardcoded in ingress — change `your-secure-api-key-here` in `manifests/phase4/ingress-auth.yml`
5. **RayService serveConfigV2** — `import_path: serve_vllm:app` expects the Python script at container path `/code/serve_vllm.py` (mounted via emptyDir in worker spec)

---

## Key Files

- `manifests/phase1/k3s-master.sh` — Run on gate7 (control plane) first
- `manifests/phase1/k3s-agent.sh` — Run on xnch-core (worker) to join cluster
- `manifests/phase4/rayservice.yml` — vLLM RayService definition
- `manifests/phase4/ingress-auth.yml` — TLS + API auth ingress
- `manifests/phase4/serve_vllm.py` — Ray Serve vLLM application

---

## External Access

- URL: `https://x-nch.com:31443`
- Auth: `Authorization: Bearer <api-key>`
- Endpoint: `/v1/chat/completions` (OpenAI-compatible)

---

## Documentation

See `docs/*.md` for detailed per-phase instructions. Phase 4 contains blockers and fixes that are critical to understand before deployment.
