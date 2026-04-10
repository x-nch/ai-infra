# KubeRay AI Infrastructure

**Execution Planner v1.1** — 3-Node Home Cluster

---

## Executive Summary

This project provisions a 3-node on-premise AI inference and training cluster using k3s, KubeRay, and vLLM — targeting GPU-accelerated LLM serving on an RTX 3090 (Node 1) with an auxiliary GTX 1650 (Node 2), orchestrated from a CPU-only control plane (Node 3). The system exposes an OpenAI-compatible inference endpoint over HTTPS via MetalLB, ingress-nginx, and cert-manager.

---

## Cluster Topology

| Node | Hardware | Role | Storage |
|------|----------|------|---------|
| **Node 1** | i9 14th Gen + 48GB RAM + RTX 3090 24GB | Primary GPU Worker + NFS Server | 2TB internal + 1TB SSD (NFS) |
| **Node 2** | i7 10th Gen + 16GB RAM + GTX 1650 4GB | Secondary GPU Worker | 1TB internal |
| **Node 3** | i5 16GB RAM (no GPU) | k3s Master + Control Plane | 500GB internal |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            EXTERNAL ACCESS                              │
│                    x-nch.com:31443 (HTTPS + API Key)                   │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      HOME ROUTER (Port Forward)                        │
│           31443 → Node 3      |      80 → Node 3 (TLS)                  │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Node 3 (k3s Master)                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                    │
│  │  k3s        │  │ ingress-    │  │  cert-      │                    │
│  │  control    │  │ nginx       │  │  manager    │                    │
│  └─────────────┘  └─────────────┘  └─────────────┘                    │
└─────────────────────────────────────────────────────────────────────────┘
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        │                            │                            │
        ▼                            ▼                            ▼
┌───────────────────┐    ┌───────────────────┐    ┌───────────────────┐
│  Node 1          │    │  Node 2          │    │  Node 3           │
│  ┌─────────────┐  │    │  ┌─────────────┐  │    │  (No GPU)         │
│  │ RTX 3090    │  │    │  │ GTX 1650    │  │    │                   │
│  │ vLLM Worker │  │    │  │ GPU Worker  │  │    │                   │
│  └─────────────┘  │    │  └─────────────┘  │    │                   │
│  ┌─────────────┐  │    │                   │    │                   │
│  │ NFS Server  │  │    │                   │    │                   │
│  │ (1TB SSD)   │  │    │                   │    │                   │
│  └─────────────┘  │    │                   │    │                   │
└───────────────────┘    └───────────────────┘    └───────────────────┘
        │
        ▼
┌───────────────────┐
│  Shared Storage  │
│  (NFS: /mnt/nfs) │
│  - Model weights │
│  - Datasets      │
│  - Checkpoints   │
└───────────────────┘
```

---

## Execution Phases

| Phase | Description | Status |
|-------|-------------|--------|
| **01** | Cluster Bootstrap (k3s + MetalLB) | Ready |
| **02** | GPU Infrastructure (NVIDIA GPU Operator) | Ready |
| **03** | Storage + KubeRay (NFS + PV/PVC + Operator) | Ready |
| **04** | vLLM + External Access (RayService + Ingress + TLS + Auth) | Ready |
| **05** | Training Infrastructure | Deferred (needs scoping) |
| **06** | Monitoring (Prometheus + Grafana) | Ready |

---

## Quick Start

```bash
# Phase 1: Cluster Bootstrap
cd manifests/phase1
./k3s-master.sh   # Run on Node 3
./k3s-agent.sh    # Run on Node 1 & 2

# Phase 2: GPU Infrastructure
kubectl apply -f gpu-operator.yml

# Phase 3: Storage + KubeRay
./nfs-server.sh   # Run on Node 1
kubectl apply -f pv-pvc.yml
helm install kuberay-operator kuberay/kuberay-operator -n ray-system

# Phase 4: vLLM + External Access
kubectl apply -f rayservice.yml
kubectl apply -f ingress-auth.yml
```

---

## External Access

- **URL**: `https://x-nch.com:31443`
- **Port**: 31443 (custom secure)
- **Authentication**: API Key via `Authorization: Bearer <key>`
- **Protocol**: OpenAI-compatible (`/v1/chat/completions`)

---

## Key Configuration

| Component | Version/Config |
|-----------|----------------|
| Kubernetes | k3s (latest) |
| GPU Operator | driver.enabled=false |
| KubeRay | v1.4.x |
| vLLM | latest (GPU image) |
| MetalLB | v0.14.5 (Layer2) |
| ingress-nginx | latest |
| cert-manager | v1.14.x |

---

## Critical Notes

1. **GPU Driver**: Host already has nvidia-driver-535, GPU Operator uses `driver.enabled=false`
2. **Port 80**: Required for cert-manager HTTP01 challenge (TLS issuance)
3. **Port 31443**: External HTTPS endpoint
4. **API Auth**: Required for external access (security)

---

## Documentation

- [Phase 1: Cluster Bootstrap](./docs/01-cluster-bootstrap.md)
- [Phase 2: GPU Infrastructure](./docs/02-gpu-infrastructure.md)
- [Phase 3: Storage + KubeRay](./docs/03-storage-kuberay.md)
- [Phase 4: vLLM + External Access](./docs/04-vllm-external.md)
- [Phase 5: Training](./docs/05-training.md) (Deferred)
- [Phase 6: Monitoring](./docs/06-monitoring.md)