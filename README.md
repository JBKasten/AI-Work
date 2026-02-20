# AI Stack — Open WebUI + LiteLLM + ComfyUI

A single-install package that wires together three open-source AI tools:

| Service | Purpose | Internal port |
|---------|---------|--------------|
| **Open WebUI** | Chat frontend — talk to any LLM | 8080 |
| **LiteLLM** | LLM proxy — single OpenAI-compatible endpoint for 100+ models | 4000 |
| **ComfyUI** | Node-based Stable Diffusion / image generation backend | 8188 |
| **Nginx** | Reverse proxy — single URL for everything | **80** / **443** |
| **PostgreSQL** | LiteLLM usage tracking & config persistence | 5432 (internal) |
| **Ollama** _(optional)_ | Local model runner (CPU or GPU) | 11434 |
| **vLLM** _(optional)_ | High-throughput local inference — OpenAI-compatible | 8000 |

Everything is wired together out of the box:
- Open WebUI talks to **LiteLLM** for all LLM calls
- Open WebUI uses **ComfyUI** for image generation
- LiteLLM routes to whichever cloud or local providers you configure
- **vLLM** plugs straight into LiteLLM as a local inference backend

---

## Quick start

```bash
git clone <this-repo> ai-stack
cd ai-stack
bash scripts/install.sh       # CPU / cloud-API mode
# or
bash scripts/install.sh --gpu # NVIDIA GPU mode
```

The script will:
1. Check Docker / Docker Compose are installed
2. Generate `.env` with random secrets
3. Build images and start all containers
4. Print the URL when ready

Open **http://localhost** in your browser.

---

## Compose variants

| Variant | Command |
|---------|---------|
| CPU / cloud APIs only | `docker compose up -d --build` |
| NVIDIA GPU (x86_64) | `docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build` |
| **GH200 Grace Hopper** (ARM64, sm_90) | `docker compose -f docker-compose.yml -f docker-compose.gh200.yml up -d --build` |
| HTTPS / Let's Encrypt | `docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d` |
| vLLM local inference (x86_64 GPU) | add `--profile vllm` to any command above |

---

## Configuration

### API keys

Edit `.env` and set whichever providers you use:

```dotenv
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GROQ_API_KEY=gsk_...
GOOGLE_API_KEY=AIza...
MISTRAL_API_KEY=...
```

Then: `docker compose up -d`

### Add / remove LLM models

Edit `litellm/config.yaml`. Supports 100+ providers:
https://docs.litellm.ai/docs/providers

```bash
docker compose restart litellm
```

### Local Ollama models

```bash
# Start Ollama sidecar
docker compose --profile ollama up -d

# Pull a model
docker exec ai-ollama ollama pull llama3.2
```

Model appears in Open WebUI as `ollama/llama3.2`.

### vLLM — high-throughput local inference

vLLM is significantly faster than Ollama on NVIDIA GPUs, especially on GH200.
It serves an OpenAI-compatible API and is pre-wired into LiteLLM.

```bash
# Set which model to load in .env
VLLM_MODEL=meta-llama/Llama-3.2-3B-Instruct
HF_TOKEN=hf_xxx   # required for gated models (Llama, etc.)

# Start with vLLM
docker compose -f docker-compose.yml -f docker-compose.vllm.yml --profile vllm up -d --build

# On GH200 with vLLM
docker compose -f docker-compose.yml -f docker-compose.gh200.yml --profile vllm up -d --build
```

Models available in Open WebUI as `vllm/local`, `vllm/llama-3.2-3b`, etc.

### GH200 Bare-Metal (no Docker)

For running directly on the host without Docker:

```bash
# 1. Install driver + CUDA (if not already done)
sudo bash scripts/install-cuda-gh200.sh
sudo reboot   # if driver was just installed

# 2. Install vLLM + Ollama + ComfyUI
sudo bash scripts/setup-gh200-bare.sh

# 3. Start services
systemctl start ollama
ollama pull llama3.2
vllm serve meta-llama/Llama-3.2-3B-Instruct --host 0.0.0.0 --dtype bfloat16
systemctl start comfyui
```

To start over from scratch, just re-run `setup-gh200-bare.sh` — it's idempotent.

### GH200 Grace Hopper (Docker)

The GH200 compose override uses:
- `nvcr.io/nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04` ARM64 base
- PyTorch nightly with `cu124` kernels targeting `sm_90`
- **Flash Attention 2** — native Hopper kernels (major throughput gain)
- **BF16** precision — native on Hopper, better accuracy than FP16
- TF32 enabled for matmuls

```bash
docker compose -f docker-compose.yml -f docker-compose.gh200.yml up -d --build
```

Prerequisite check:
```bash
docker run --rm --gpus all nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

### ComfyUI model packs

Download common Stable Diffusion / FLUX model packs with one command:

```bash
# Stable Diffusion 1.5 (~2 GB)
bash scripts/download-models.sh sd15

# SDXL 1.0 (~12 GB)
bash scripts/download-models.sh sdxl

# FLUX.1-schnell (~24 GB)
bash scripts/download-models.sh flux-schnell

# FLUX.1-dev (~24 GB, requires HuggingFace token + license acceptance)
HF_TOKEN=hf_xxx bash scripts/download-models.sh flux-dev

# Upscalers (ESRGAN, ~400 MB)
bash scripts/download-models.sh upscalers

# Everything (large!)
bash scripts/download-models.sh all
```

Or copy models manually:
```bash
docker cp /path/to/model.safetensors ai-comfyui:/app/models/checkpoints/
```

### Connect Open WebUI to ComfyUI

1. **Settings → Images**
2. Image Generation Engine → **ComfyUI**
3. URL: `http://comfyui:8188`

### HTTPS / Let's Encrypt

```bash
# Domain DNS must point to this server first
bash scripts/setup-ssl.sh your.domain.com admin@your.domain.com
```

This will:
1. Issue a cert via Let's Encrypt ACME
2. Swap Nginx to the SSL config
3. Start the certbot auto-renewal container
4. Restart everything on port 443

---

## URLs

| What | URL |
|------|-----|
| Open WebUI (chat) | http://localhost/ |
| LiteLLM API | http://localhost/litellm/v1 |
| LiteLLM admin UI | http://localhost/litellm/ui |
| ComfyUI | http://localhost/comfyui/ |

---

## Common commands

```bash
# View all logs
docker compose logs -f

# View one service
docker compose logs -f open-webui

# Restart a service
docker compose restart litellm

# Stop everything (keep data)
docker compose down

# Stop and wipe all data
docker compose down -v

# Update to latest versions
bash scripts/update.sh
```

---

## Architecture

```
Browser
  │
  ▼
Nginx :80/:443
  ├── /              → Open WebUI :8080
  ├── /litellm/      → LiteLLM    :4000  ──► OpenAI / Anthropic / Groq / Mistral / ...
  └── /comfyui/      → ComfyUI    :8188       └── Ollama (local, --profile ollama)
                                               └── vLLM  (local, --profile vllm)

Open WebUI ──► LiteLLM   (LLM chat / completions)
Open WebUI ──► ComfyUI   (image generation)
LiteLLM    ──► PostgreSQL (usage logs, model config)
```

---

## Requirements

- Docker 24+ with Docker Compose plugin
- 8 GB RAM minimum; 16 GB+ for local models
- **NVIDIA GPU**: `nvidia-container-toolkit` + driver 550+
- **GH200**: ARM64 or x86_64 host, driver 550+, `nvidia-container-toolkit` (Docker) or Python 3.11+ (bare-metal)
- **HTTPS**: domain pointing at server, ports 80 + 443 open

---

## License

Each component retains its own license:
- [Open WebUI](https://github.com/open-webui/open-webui) — MIT
- [LiteLLM](https://github.com/BerriAI/litellm) — MIT
- [ComfyUI](https://github.com/comfyanonymous/ComfyUI) — GPL-3.0
- [vLLM](https://github.com/vllm-project/vllm) — Apache 2.0
- [Ollama](https://github.com/ollama/ollama) — MIT

Integration code in this repository is MIT licensed.
