# ─────────────────────────────────────────────────────────────────────────────
# ComfyUI Dockerfile
# Supports CPU (default) and NVIDIA GPU (see docker-compose.gpu.yml)
# ─────────────────────────────────────────────────────────────────────────────

ARG BASE_IMAGE=python:3.11-slim
FROM ${BASE_IMAGE}

ARG COMFYUI_TAG=latest
LABEL org.opencontainers.image.title="ComfyUI (AI-Stack)"
LABEL org.opencontainers.image.description="ComfyUI node-based Stable Diffusion UI"

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    wget \
    curl \
    ffmpeg \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    build-essential \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git . \
    && if [ "${COMFYUI_TAG}" != "latest" ]; then git checkout "${COMFYUI_TAG}"; fi

# Install Python dependencies
# CPU-only torch by default; GPU override handled by docker-compose.gpu.yml
RUN pip install --no-cache-dir torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cpu

RUN pip install --no-cache-dir -r requirements.txt

# Install ComfyUI Manager (popular node manager — highly recommended)
RUN git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager \
    && pip install --no-cache-dir -r custom_nodes/ComfyUI-Manager/requirements.txt

# Create volume mount points
RUN mkdir -p models/checkpoints models/vae models/loras models/controlnet \
    models/upscale_models models/embeddings models/clip \
    output input custom_nodes

# Expose ComfyUI port
EXPOSE 8188

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8188/ || exit 1

ENTRYPOINT ["python", "main.py"]
CMD ["--listen", "0.0.0.0", "--port", "8188"]
