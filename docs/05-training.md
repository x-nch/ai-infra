# Phase 5: Training Infrastructure

**Status**: DEFERRED - Requires Scoping

---

## Overview

This phase sets up distributed training infrastructure using Ray Train and DeepSpeed. However, the original plan is a stub and requires additional information before implementation.

## Required Information

Before proceeding, please answer:

### 1. Training Use Case
- **What model do you want to fine-tune?** (e.g., Llama 2 7B, Mistral 7B, custom model)
- **What is the training goal?** (instruction tuning, domain adaptation, RLHF, etc.)

### 2. Dataset
- **What is your dataset format?** (JSONL, CSV, Parquet, HuggingFace dataset)
- **Where is the data stored?** (local, remote URL, HuggingFace Hub)
- **Dataset size?** (num examples, total tokens)

### 3. Training Method
- **Full fine-tune or PEFT?**
  - Full: All parameters updated (requires ~30GB VRAM for 7B)
  - LoRA: Low-rank adaptation (requires ~10GB VRAM)
  - QLoRA: Quantized + LoRA (requires ~6GB VRAM)

### 4. Checkpoint Strategy
- **How often to save checkpoints?** (every N steps, epoch-based)
- **Where to store checkpoints?** (NFS, local)
- **Max storage budget?** (100GB, 500GB, etc.)

### 5. Experiment Tracking
- **Which tool?**
  - Weights & Biases (wandb)
  - MLflow
  - TensorBoard (local)
  - None

### 6. Training Scale
- **Single GPU (RTX 3090) or multi-GPU?**
- **Expected training time?** (hours, days)

---

## Estimated VRAM Requirements

| Model | Full Fine-tune | LoRA | QLoRA |
|-------|---------------|------|-------|
| 7B | ~30GB | ~10GB | ~6GB |
| 13B | ~60GB | ~20GB | ~10GB |
| 34B | ~80GB (multi-GPU) | ~40GB | ~20GB |

**Your RTX 3090 (24GB)**: Use QLoRA or LoRA only for 7B models.

---

## When Ready

Once you provide the above information, I will generate:

1. **Training RayCluster manifest** with GPU nodeSelector
2. **DeepSpeed ZeRO config** optimized for 24GB VRAM
3. **Data loading pipeline** for your dataset format
4. **Training script** with checkpointing and logging
5. **Experiment tracking** integration (wandb/mlflow)

---

## Placeholder: Example Training Manifest

```yaml
# Example (for reference only - needs customization)
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: training-cluster
  namespace: ray-training
spec:
  headGroupSpec:
    rayStartParams:
      num-cpus: "4"
    template:
      spec:
        containers:
        - name: ray-head
          image: rayproject/ray:2.9.3-gpu
          resources:
            requests:
              cpu: "4"
              memory: "16Gi"
  workerGroupSpecs:
  - groupName: gpu-workers
    replicas: 1
    rayStartParams:
      num-cpus: "8"
      num-gpus: "1"
      memory: "32Gi"
    template:
      spec:
        containers:
        - name: training
          image: your-training-image:latest
          resources:
            limits:
              nvidia.com/gpu: "1"
          nodeSelector:
            gpu-type: rtx3090
```

---

## Contact

To proceed with Phase 5, please provide answers to the questions above.