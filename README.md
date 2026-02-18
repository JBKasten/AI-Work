# AI Stack — Open WebUI + LiteLLM + ComfyUI

A single-install package that wires together three open-source AI tools:

| Service | Purpose | Internal port |
|---------|---------|--------------|
| **Open WebUI** | Chat frontend — talk to any LLM | 8080 |
| **LiteLLM** | LLM proxy — single OpenAI-compatible endpoint for 100+ models | 4000 |
| **ComfyUI** | Node-based Stable Diffusion / image generation backend | 8188 |
| **Nginx** | Reverse proxy — single URL for everything | **80** (configurable) |
| **PostgreSQL** | LiteLLM usage tracking & config persistence | 5432 (internal) |
| **Ollama** _(optional)_ | Local model runner (CPU or GPU) | 11434 |

Everything is wired together out of the box:
- Open WebUI talks to **LiteLLM** for all LLM calls
- Open WebUI is pre-configured to use **ComfyUI** for image generation
- LiteLLM fan-outs to whichever cloud or local providers you configure

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

## Manual setup

```bash
cp .env.example .env
# edit .env and add your API keys
docker compose up -d --build
```

### With NVIDIA GPU

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
```

---

## Configuration

### Add API keys

Edit `.env` and set whichever providers you want:

```dotenv
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GROQ_API_KEY=gsk_...
GOOGLE_API_KEY=AIza...
# etc.
```

Then restart: `docker compose up -d`

### Add / remove LLM models

Edit `litellm/config.yaml`. Full model list:
https://docs.litellm.ai/docs/providers

Restart LiteLLM after changes: `docker compose restart litellm`

### Use local Ollama models

Start the Ollama sidecar:
```bash
docker compose --profile ollama up -d
```

Pull a model:
```bash
docker exec ai-ollama ollama pull llama3.2
```

The model appears automatically in Open WebUI as `ollama/llama3.2`.

### Download Stable Diffusion models for ComfyUI

Place checkpoint files in the `comfyui-models` Docker volume. Easiest way:

```bash
docker exec -it ai-comfyui bash
# Inside container:
wget -O models/checkpoints/v1-5-pruned-emaonly.safetensors \
  https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors
```

Or copy from host:
```bash
docker cp /path/to/model.safetensors ai-comfyui:/app/models/checkpoints/
```

### Connect Open WebUI to ComfyUI for image generation

1. In Open WebUI, go to **Settings → Images**
2. Set Image Generation Engine to **ComfyUI**
3. URL: `http://comfyui:8188` (internal Docker DNS — already set as env var)

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

# View logs for one service
docker compose logs -f open-webui

# Restart a service
docker compose restart litellm

# Stop everything
docker compose down

# Stop and delete all data
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
Nginx :80
  ├── /              → Open WebUI :8080
  ├── /litellm/      → LiteLLM    :4000  ──► OpenAI / Anthropic / Groq / ...
  └── /comfyui/      → ComfyUI    :8188       Ollama (local)

Open WebUI ──► LiteLLM  (all LLM chat/completion calls)
Open WebUI ──► ComfyUI  (image generation)
LiteLLM    ──► PostgreSQL (usage logs, model config)
```

---

## Requirements

- Docker 24+ with Docker Compose plugin
- 8 GB RAM minimum (16 GB recommended with local models)
- For GPU: NVIDIA GPU + `nvidia-container-toolkit`

---

## License

Each component retains its own license:
- [Open WebUI](https://github.com/open-webui/open-webui) — MIT
- [LiteLLM](https://github.com/BerriAI/litellm) — MIT
- [ComfyUI](https://github.com/comfyanonymous/ComfyUI) — GPL-3.0

Integration code in this repository is MIT licensed.
