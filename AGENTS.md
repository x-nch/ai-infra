# AGENTS.md - KubeRay AI Infrastructure

Infrastructure-as-code repository for a 2-node GPU cluster running k3s, KubeRay, and vLLM. No traditional builds—work is deploying Kubernetes manifests and running shell scripts.

---

## Quick Reference

| Task | Command |
|------|---------|
| Deploy manifest | `kubectl apply -f manifests/phase<N>/<file>.yml` |
| Dry-run YAML | `kubectl apply --dry-run=client -f <file>.yml` |
| Run node script | `sudo ./manifests/phase<N>/<script>.sh` |
| Check cluster | `kubectl get nodes -o wide` |
| Check pods | `kubectl get pods -A` |
| Port-forward | `kubectl port-forward -n <ns> svc/<svc> <local>:<remote>` |

---

## Cluster Topology

- **gate7** (192.168.1.8): k3s Master + GTX 1650 4GB
- **xnch-core** (192.168.1.10): GPU Worker + NFS Server + RTX 3090 24GB

---

## Phase Execution Order

| Phase | Description | Prereq |
|-------|-------------|--------|
| 1 | k3s + MetalLB | None |
| 2 | GPU Operator | Phase 1 |
| 3 | NFS + KubeRay | Phase 2 |
| 4 | vLLM + Ingress | Phase 3 |
| 6 | Monitoring | Phase 4 |

---

## Linting & Validation

### YAML Manifests
```bash
# Syntax check with Python
python3 -c "import yaml; yaml.safe_load_all(open('manifests/phase<N>/<file>.yml'))"

# Dry-run (no cluster)
kubectl apply --dry-run=client -f manifests/phase<N>/<file>.yml

# Full validation
kubectl apply --dry-run=server -f manifests/phase<N>/<file>.yml
```

### Shell Scripts
```bash
# Install linter
sudo apt-get install shellcheck

# Lint all scripts
find manifests -name "*.sh" -exec shellcheck {} \;

# Lint specific script
shellcheck manifests/phase<N>/<script>.sh
```

### Python (serve_vllm.py)
```bash
pip install ruff black mypy

ruff format manifests/phase4/serve_vllm.py      # Format
ruff check manifests/phase4/serve_vllm.py        # Lint
mypy manifests/phase4/serve_vllm.py --ignore-missing-imports  # Type check
```

---

## Testing

### End-to-End Inference
```bash
./manifests/phase4/inference-test.sh

# Manual API test
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}'

# Health check
curl http://localhost:8000/health
```

### Component Inspection
```bash
kubectl logs -n llm-serving -l ray.io/group=worker-group --tail=100
kubectl describe rayservice -n llm-serving
```

---

## Code Style

### YAML (Kubernetes)

- 2-space indentation, no tabs
- Order: `apiVersion`, `kind`, `metadata`, `spec`
- Include `app`/`component` labels
- Always specify resource requests/limits
- Use `imagePullPolicy: IfNotPresent`
- Include `readinessProbe`/`livenessProbe`

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
  rayClusterConfig:
    workerGroupSpecs:
    - replicas: 1
      groupName: vllm-workers
```

### Shell Scripts

- Shebang: `#!/bin/bash` (not `#!/bin/sh`)
- `set -e` at top (use `set -o pipefail` for pipelines)
- Constants: `UPPER_SNAKE_CASE`
- Local vars: `lowerCamelCase`
- Functions: `function_name()` (no `function` keyword)
- Quote variables: `"$VAR"`
- Use colors: `RED`, `GREEN`, `YELLOW`, `NC` (No Color)

```bash
#!/bin/bash
set -e

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/$(basename "$0" .sh).log"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

function validate_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl not found${NC}" >&2
        return 1
    fi
}
```

### Python (serve_vllm.py)

- PEP 8 style
- Imports: stdlib, third-party, local
- Type hints for parameters and return values
- Use `@dataclass` for data structures
- Async for I/O: `async def`, `await`

```python
import os
import logging
from typing import Dict, List, Optional
from dataclasses import dataclass

from fastapi import FastAPI, HTTPException
import ray
from ray import serve

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@dataclass
class ChatMessage:
    role: str
    content: str

async def generate(prompt: str, temperature: float = 0.7) -> Dict:
    """Generate text from prompt."""
    ...
```

---

## Important Notes

1. **MetalLB**: Requires both `IPAddressPool` AND `L2Advertisement`
2. **GPU Operator**: Uses `driver.enabled=false` (host has nvidia-driver-535)
3. **PV/PVC**: Match `accessModes` between PV and PVC
4. **API key**: Change `your-secure-api-key-here` in `manifests/phase4/ingress-auth.yml`
5. **RayService**: `import_path: serve_vllm:app` expects `/code/serve_vllm.py` in container

---

## External Access

- **URL**: `https://x-nch.com:31443`
- **Auth**: `Authorization: Bearer <api-key>`
- **Endpoint**: `/v1/chat/completions` (OpenAI-compatible)

---

## Key Files

| File | Purpose |
|------|---------|
| `manifests/phase4/rayservice.yml` | vLLM RayService |
| `manifests/phase4/ingress-auth.yml` | TLS + API auth |
| `manifests/phase4/serve_vllm.py` | Ray Serve app |
| `manifests/phase1/k3s-agent.sh` | Worker node setup |

---

## Documentation

See `docs/*.md` for per-phase instructions.
