"""
vLLM Ray Serve Application
Exposes OpenAI-compatible /v1/chat/completions endpoint

Usage:
  This file is used as the import_path in RayService serveConfigV2
  The application will be deployed as a Ray Serve deployment

Environment Variables:
  MODEL_ID: HuggingFace model ID (default: meta-llama/Llama-2-7b-chat-hf)
  HF_TOKEN: HuggingFace token for gated models
  VLLM_MAX_MODEL_LEN: Maximum model length (default: 4096)
  VLLM_GPU_MEMORY_UTILIZATION: GPU memory utilization (default: 0.85)

Example RayService config:
  serveConfigV2: |
    import_path: serve_vllm:app
    runtime_env:
      env_vars:
        MODEL_ID: "meta-llama/Llama-2-7b-chat-hf"
    deployments:
    - name: vllm-deployment
      num_replicas: 1
"""

import os
import logging
from typing import AsyncIterator, Dict, List, Optional, Union
from dataclasses import dataclass

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
import ray
from ray import serve
from vllm.engine.arg_utils import AsyncEngineArgs
from vllm.engine.async_llm_engine import AsyncLLMEngine
from vllm.sampling_params import SamplingParams
from vllm.utils import get_random_uuid

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize Ray Serve
ray.init(address="auto", namespace="vllm")

# Get configuration from environment
MODEL_ID = os.environ.get("MODEL_ID", "meta-llama/Llama-2-7b-chat-hf")
HF_TOKEN = os.environ.get("HF_TOKEN", None)
MAX_MODEL_LEN = int(os.environ.get("VLLM_MAX_MODEL_LEN", "4096"))
GPU_MEMORY_UTIL = float(os.environ.get("VLLM_GPU_MEMORY_UTILIZATION", "0.85"))


@dataclass
class ChatMessage:
    role: str
    content: str


@dataclass
class ChatCompletionRequest:
    model: str
    messages: List[ChatMessage]
    temperature: float = 0.7
    max_tokens: int = 512
    top_p: float = 0.95
    top_k: int = 50
    stream: bool = False
    stop: Optional[Union[str, List[str]]] = None


@serve.deployment(
    name="vllm-deployment",
    route_prefix="/",
    num_replicas=1,
    ray_actor_options={
        "num_gpus": 1,
        "num_cpus": 4,
    },
    max_restart_attempts=5,
)
class VLLMDeployment:
    def __init__(self):
        logger.info(f"Initializing vLLM with model: {MODEL_ID}")

        engine_args = AsyncEngineArgs(
            model=MODEL_ID,
            trust_remote_code=True,
            tensor_parallel_size=1,
            gpu_memory_utilization=GPU_MEMORY_UTIL,
            max_num_seqs=256,
            max_model_len=MAX_MODEL_LEN,
            enforce_eager=False,
            dtype="auto",
            quantization=None,
            hf_overrides=None,
        )

        self.engine = AsyncLLMEngine.from_engine_args(engine_args)
        logger.info(f"vLLM engine initialized successfully")

    async def generate(
        self,
        prompt: str,
        temperature: float = 0.7,
        max_tokens: int = 512,
        top_p: float = 0.95,
        top_k: int = 50,
        stop: Optional[Union[str, List[str]]] = None,
    ) -> Dict:
        """Generate text from prompt"""
        sampling_params = SamplingParams(
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            top_k=top_k,
            stop=stop,
            ignore_eos=False,
        )

        request_id = f"chatcmpl-{get_random_uuid()}"

        results_generator = self.engine.generate(prompt, sampling_params, request_id)

        final_output = None
        async for output in results_generator:
            final_output = output

        if final_output is None:
            raise HTTPException(status_code=500, detail="Generation failed")

        return {
            "id": request_id,
            "object": "chat.completion",
            "created": final_output.arrival_time,
            "model": MODEL_ID,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": final_output.outputs[0].text,
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": len(final_output.prompt_token_ids),
                "completion_tokens": len(final_output.outputs[0].token_ids),
                "total_tokens": len(final_output.prompt_token_ids)
                + len(final_output.outputs[0].token_ids),
            },
        }

    async def generate_stream(self, prompt: str, **kwargs) -> AsyncIterator[str]:
        """Generate text with streaming"""
        sampling_params = SamplingParams(
            temperature=kwargs.get("temperature", 0.7),
            max_tokens=kwargs.get("max_tokens", 512),
            top_p=kwargs.get("top_p", 0.95),
            top_k=kwargs.get("top_k", 50),
            stop=kwargs.get("stop", None),
        )

        request_id = f"chatcmpl-{get_random_uuid()}"

        async for output in self.engine.generate(prompt, sampling_params, request_id):
            chunk = {
                "id": request_id,
                "object": "chat.completion.chunk",
                "created": output.arrival_time,
                "model": MODEL_ID,
                "choices": [
                    {
                        "index": 0,
                        "delta": {"content": output.outputs[0].text},
                        "finish_reason": None,
                    }
                ],
            }
            yield f"data: {JSONResponse(content=chunk).body.decode()}\n\n"

        yield "data: [DONE]\n\n"


# FastAPI app for OpenAI compatibility
app = FastAPI(title="vLLM OpenAI API", version="1.0.0")


@serve.ingress(app)
class APIIngress:
    def __init__(self, d):
        self.d = d

    @app.post("/v1/chat/completions")
    async def chat_completions(self, request: Request):
        """OpenAI-compatible chat completions endpoint"""
        body = await request.json()

        messages = body.get("messages", [])
        model = body.get("model", MODEL_ID)
        temperature = body.get("temperature", 0.7)
        max_tokens = body.get("max_tokens", 512)
        top_p = body.get("top_p", 0.95)
        stream = body.get("stream", False)

        # Extract last user message
        last_message = None
        for msg in reversed(messages):
            if isinstance(msg, dict) and msg.get("role") == "user":
                last_message = msg.get("content", "")
                break
            elif isinstance(msg, ChatMessage) and msg.role == "user":
                last_message = msg.content
                break

        if not last_message:
            raise HTTPException(status_code=400, detail="No user message found")

        if stream:
            return self.d.generate_stream(
                prompt=last_message,
                temperature=temperature,
                max_tokens=max_tokens,
                top_p=top_p,
            )

        # Non-streaming
        result = await self.d.generate(
            prompt=last_message,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
        )

        return JSONResponse(content=result)

    @app.get("/v1/models")
    async def list_models(self):
        """List available models"""
        return {
            "object": "list",
            "data": [
                {
                    "id": MODEL_ID,
                    "object": "model",
                    "created": 1677610602,
                    "owned_by": "vllm",
                    "permission": [],
                }
            ],
        }

    @app.get("/health")
    async def health(self):
        """Health check endpoint"""
        return {"status": "healthy", "model": MODEL_ID}

    @app.get("/metrics")
    async def metrics(self):
        """Prometheus metrics endpoint"""
        return {"message": "Metrics endpoint - implement with prometheus_client"}


# Create the application
app = APIIngress.bind(VLLMDeployment.bind())
