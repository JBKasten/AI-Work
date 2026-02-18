# ─────────────────────────────────────────────────────────────────────────────
# vLLM Dockerfile — standard NVIDIA GPU (x86_64, sm_80+)
# Use this via docker-compose.vllm.yml on non-GH200 NVIDIA GPUs
# ─────────────────────────────────────────────────────────────────────────────

FROM nvcr.io/nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

LABEL org.opencontainers.image.title="vLLM (AI-Stack)"

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV VLLM_WORKER_MULTIPROC_METHOD=spawn

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-dev \
    python3-pip \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && python -m pip install --upgrade pip

RUN pip install --no-cache-dir vllm huggingface-hub

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD curl -f http://localhost:8000/health || exit 1

ENTRYPOINT ["python", "-m", "vllm.entrypoints.openai.api_server"]
CMD [ \
    "--host", "0.0.0.0", \
    "--port", "8000", \
    "--model", "meta-llama/Llama-3.2-3B-Instruct", \
    "--dtype", "float16", \
    "--max-model-len", "8192", \
    "--gpu-memory-utilization", "0.85" \
]
