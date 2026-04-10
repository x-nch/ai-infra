# Phase 4: vLLM + External Access

**Duration**: 2-3 hours | **Severity**: Contains 2 Blockers + 2 Fixes

---

## Overview

This phase deploys vLLM for LLM inference with proper Ray Serve integration, configures external HTTPS access via ingress-nginx + cert-manager, and adds API key authentication.

## Prerequisites

- k3s cluster running (Phase 1)
- GPU Operator installed (Phase 2)
- NFS + KubeRay installed (Phase 3)

---

## T4.1: vLLM Serve Script

**Blocker**: serveConfigV2 references `vllm_vllm:app` which doesn't exist. Need actual serve.py with correct Ray Serve + vLLM integration.

```bash
cat > manifests/phase4/serve_vllm.py << 'EOF'
"""
vLLM Ray Serve Application
Exposes OpenAI-compatible /v1/chat/completions endpoint
"""

import os
from typing import Dict, List, Optional, Union
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import ray
from ray import serve
from vllm.engine.arg_utils import AsyncEngineArgs
from vllm.engine.async_llm_engine import AsyncLLMEngine
from vllm.sampling_params import SamplingParams
from vllm.utils import get_random_uuid

# Initialize Ray Serve
ray.init(address="auto", namespace="vllm")

# Get model from environment variable
MODEL_ID = os.environ.get("MODEL_ID", "meta-llama/Llama-2-7b-chat-hf")
HF_TOKEN = os.environ.get("HF_TOKEN", None)


@serve.deployment(
    name="vllm-deployment",
    route_prefix="/",
    num_replicas=1,
    ray_actor_options={
        "num_gpus": 1,
        "num_cpus": 4,
    }
)
class VLLMDeployment:
    def __init__(self):
        print(f"Initializing vLLM with model: {MODEL_ID}")
        
        engine_args = AsyncEngineArgs(
            model=MODEL_ID,
            trust_remote_code=True,
            tensor_parallel_size=1,
            gpu_memory_utilization=0.85,
            max_num_seqs=256,
            max_model_len=4096,
            enforce_eager=False,  # Use CUDA graph for better performance
            dtype="auto",
            quantization=None,
        )
        
        self.engine = AsyncLLMEngine.from_engine_args(engine_args)
        print(f"vLLM engine initialized successfully")
    
    async def generate(self, prompt: str, **kwargs) -> Dict:
        """Generate text from prompt"""
        sampling_params = SamplingParams(
            temperature=kwargs.get("temperature", 0.7),
            max_tokens=kwargs.get("max_tokens", 512),
            top_p=kwargs.get("top_p", 0.95),
            top_k=kwargs.get("top_k", 50),
            stop=kwargs.get("stop", None),
        )
        
        request_id = get_random_uuid()
        
        results_generator = self.engine.generate(prompt, sampling_params, request_id)
        
        final_output = None
        async for output in results_generator:
            final_output = output
        
        if final_output is None:
            raise HTTPException(status_code=500, detail="Generation failed")
        
        return {
            "id": f"chatcmpl-{request_id}",
            "object": "chat.completion",
            "created": final_output.arrival_time,
            "model": MODEL_ID,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": final_output.outputs[0].text
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": final_output.prompt_token_ids,
                "completion_tokens": len(final_output.outputs[0].token_ids),
                "total_tokens": len(final_output.prompt_token_ids) + len(final_output.outputs[0].token_ids)
            }
        }


# FastAPI app for OpenAI compatibility
app = FastAPI()


@serve.ingress(app)
class APIIngress:
    def __init__(self, d):
        self.d = d
    
    @app.post("/v1/chat/completions")
    async def chat_completions(self, request: dict):
        """OpenAI-compatible chat completions endpoint"""
        messages = request.get("messages", [])
        model = request.get("model", MODEL_ID)
        temperature = request.get("temperature", 0.7)
        max_tokens = request.get("max_tokens", 512)
        top_p = request.get("top_p", 0.95)
        
        # Extract last user message
        last_message = None
        for msg in reversed(messages):
            if msg.get("role") == "user":
                last_message = msg.get("content", "")
                break
        
        if not last_message:
            raise HTTPException(status_code=400, detail="No user message found")
        
        # Call vLLM deployment
        result = await self.d.generate(
            prompt=last_message,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p
        )
        
        return result
    
    @app.get("/health")
    async def health(self):
        return {"status": "healthy"}
    
    @app.get("/v1/models")
    async def list_models(self):
        return {
            "object": "list",
            "data": [
                {
                    "id": MODEL_ID,
                    "object": "model",
                    "created": 1677610602,
                    "owned_by": "vllm"
                }
            ]
        }


# Create the application
app = APIIngress.bind(VLLMDeployment.bind())
EOF

echo "Created serve_vllm.py"
```

---

## T4.2: Corrected RayService Manifest

**Fix**: Use verified `rayproject/ray:2.9.3-gpu` image tag, correct import_path, add model cache volume.

```bash
cat > manifests/phase4/rayservice.yml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: llm-serving
---
# Secret for HuggingFace token (optional, for gated models)
apiVersion: v1
kind: Secret
metadata:
  name: hf-token
  namespace: llm-serving
type: Opaque
stringData:
  token: ""  # Add your HuggingFace token here
---
apiVersion: ray.io/v1
kind: RayService
metadata:
  name: vllm-service
  namespace: llm-serving
spec:
  serviceUnhealthySecondThreshold: 600
  deploymentUnhealthySecondThreshold: 300
  rayClusterConfig:
    headGroupSpec:
      rayStartParams:
        dashboard-host: "0.0.0.0"
        num-cpus: "4"
        num-gpus: "0"
      template:
        spec:
          containers:
          - name: ray-head
            image: rayproject/ray:2.9.3-gpu
            imagePullPolicy: IfNotPresent
            env:
            - name: RAY_memory_monitor_refresh_ms
              value: "0"
            resources:
              requests:
                cpu: "4"
                memory: "16Gi"
              limits:
                cpu: "4"
                memory: "16Gi"
            volumeMounts:
            - name: model-cache
              mountPath: /root/.cache/huggingface
          volumes:
          - name: model-cache
            persistentVolumeClaim:
              claimName: model-storage
          serviceAccountName: default
    workerGroupSpecs:
    - groupName: vllm-workers
      replicas: 1
      minReplicas: 1
      maxReplicas: 2
      numCurrentWorkers: 1
      rayStartParams:
        num-cpus: "8"
        num-gpus: "1"
        memory: "32Gi"
      template:
        spec:
          containers:
          - name: vllm
            image: rayproject/ray:2.9.3-gpu
            imagePullPolicy: IfNotPresent
            env:
            - name: MODEL_ID
              value: "meta-llama/Llama-2-7b-chat-hf"
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
            - name: RAY_memory_monitor_refresh_ms
              value: "0"
            resources:
              limits:
                nvidia.com/gpu: "1"
              requests:
                cpu: "8"
                memory: "32Gi"
            volumeMounts:
            - name: model-cache
              mountPath: /root/.cache/huggingface
            - name: code
              mountPath: /code
          volumes:
          - name: model-cache
            persistentVolumeClaim:
              claimName: model-storage
          - name: code
            emptyDir: {}
          nodeSelector:
            gpu-type: rtx3090
          tolerations:
          - key: "nvidia.com/gpu"
            operator: "Exists"
            effect: "NoSchedule"
          serviceAccountName: default
  serveConfigV2: |
    import_path: serve_vllm:app
    runtime_env:
      working_dir: "s3://ray-demo-bucket/serve_vllm/"
      env_vars:
        MODEL_ID: "meta-llama/Llama-2-7b-chat-hf"
    deployments:
    - name: vllm-deployment
      num_replicas: 1
      max_restart_attempts: 5
      ray_actor_options:
        num_gpus: 1
        num_cpus: 4
        memory: "32Gi"
EOF

# Apply
kubectl apply -f manifests/phase4/rayservice.yml

# Watch status
kubectl get rayservices.ray.io -n llm-serving -w
kubectl describe rayservice vllm-service -n llm-serving
```

---

## T4.3: API Key Authentication

**Security Fix**: Endpoint is internet-exposed with no auth. Add nginx auth_request validation.

```bash
cat > manifests/phase4/ingress-auth.yml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: api-key-secret
  namespace: llm-serving
type: Opaque
stringData:
  API_KEY: "your-secure-api-key-here-change-me"  # CHANGE THIS!
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-ingress
  namespace: llm-serving
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    # Authentication snippet
    nginx.ingress.kubernetes.io/configuration-snippet: |
      auth_request /auth;
      error_page 401 = /401;
    nginx.ingress.kubernetes.io/server-snippet: |
      location /auth {
        proxy_pass http://vllm-service-head-svc:8000/health;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI $request_uri;
        
        # Check Authorization header
        set $auth_status "failed";
        if ($http_authorization = "Bearer your-secure-api-key-here-change-me") {
          set $auth_status "passed";
        }
        
        if ($auth_status = "failed") {
          return 401;
        }
      }
      location /401 {
        return 401 '{"error": "Unauthorized", "message": "Invalid or missing API key"}';
        add_header Content-Type application/json;
      }
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - x-nch.com
    secretName: vllm-tls
  rules:
  - host: x-nch.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vllm-service-head-svc
            port:
              number: 8000
EOF

# Note: For production, use a more secure auth method like external auth service
# or Kubernetes Ingress with built-in basic auth
```

---

## T4.4: cert-manager + TLS Configuration

**Blocker**: HTTP01 ACME challenge requires port 80 reachable from internet.

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

# Create ClusterIssuer
cat > manifests/phase4/cert-manager.yml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@x-nch.com  # CHANGE THIS
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
---
# Update ingress to use TLS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-ingress
  namespace: llm-serving
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - x-nch.com
    secretName: vllm-tls
  rules:
  - host: x-nch.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vllm-service-head-svc
            port:
              number: 8000
EOF

# Apply
kubectl apply -f manifests/phase4/cert-manager.yml

# Check certificate status
kubectl get certificates -n llm-serving
kubectl describe certificate vllm-tls -n llm-serving
```

---

## T4.5: End-to-End Inference Validation

```bash
cat > manifests/phase4/inference-test.sh << 'EOF'
#!/bin/bash
set -e

echo "=== vLLM End-to-End Inference Validation ==="

# Port forward to vLLM service (run in background)
echo "Starting port-forward..."
kubectl port-forward -n llm-serving svc/vllm-service-head-svc 8000:8000 &
PF_PID=$!

# Wait for port-forward to be ready
sleep 5

# Test health endpoint
echo "Testing health endpoint..."
curl -s http://localhost:8000/health | jq .

# Test list models
echo "Testing /v1/models..."
curl -s http://localhost:8000/v1/models | jq .

# Test chat completions
echo "Testing /v1/chat/completions..."
RESPONSE=$(curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-2-7b-chat-hf",
    "messages": [{"role": "user", "content": "Hello! How are you?"}],
    "max_tokens": 50
  }')

echo "$RESPONSE" | jq .

# Check for valid response
if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
  echo ""
  echo "=== INFERENCE TEST PASSED ==="
  RESULT=0
else
  echo ""
  echo "=== INFERENCE TEST FAILED ==="
  RESULT=1
fi

# Cleanup
kill $PF_PID 2>/dev/null

exit $RESULT
EOF

chmod +x manifests/phase4/inference-test.sh

# Run validation
./manifests/phase4/inference-test.sh
```

---

## Router Port Forwarding Configuration

**CRITICAL**: Required router configuration for external access + TLS

| External Port | Internal IP | Internal Port | Purpose |
|---------------|-------------|---------------|---------|
| 80 | 192.168.1.103 | 80 | cert-manager HTTP01 (TLS) |
| 443 | 192.168.1.103 | 443 | ingress-nginx HTTPS |
| 31443 | 192.168.1.103 | 31443 | Custom external port |

### Router Configuration Steps

1. **Log into your home router**
2. **Port Forwarding / NAT Rules**:
   - Forward `External Port 80` → `Node 3 IP:80`
   - Forward `External Port 443` → `Node 3 IP:443` (if using standard HTTPS)
   - Forward `External Port 31443` → `Node 3 IP:31443`

3. **Find NodePort for ingress-nginx**:
```bash
kubectl get svc -n ingress-nginx
# Look for NODEPORT ports like 80:xxxxx, 443:xxxxx
```

---

## Validation Commands

```bash
# Check RayService status
kubectl get rayservices.ray.io -n llm-serving

# Check ingress
kubectl get ingress -n llm-serving

# Check certificate
kubectl get certificate -n llm-serving

# Test internally first (before enabling external access)
kubectl port-forward -n llm-serving svc/vllm-service-head-svc 8000:8000
curl http://localhost:8000/v1/models
```

---

## Troubleshooting

### vLLM Worker Not Starting

```bash
# Check worker logs
kubectl logs -n llm-serving -l ray.io/group=vllm-workers

# Check GPU availability
kubectl describe nodes | grep nvidia.com/gpu
```

### TLS Certificate Not Issuing

```bash
# Check cert-manager pods
kubectl get pods -n cert-manager

# Check certificate status
kubectl describe certificate vllm-tls -n llm-serving

# Check cert-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
```

---

## Next Phase

Proceed to [Phase 5: Training Infrastructure](./05-training.md) (Deferred - needs scoping)

Or skip to [Phase 6: Monitoring](./06-monitoring.md)