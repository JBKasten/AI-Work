#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — one-shot install script
# Usage: bash scripts/install.sh [--gpu] [--gh200]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
GPU=false
GH200=false

# Parse args
for arg in "$@"; do
    case $arg in
        --gpu)   GPU=true ;;
        --gh200) GH200=true; GPU=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

info()    { echo "[AI-Stack]  $*"; }
success() { echo "[AI-Stack] ✓ $*"; }
warn()    { echo "[AI-Stack] ! $*" >&2; }
die()     { echo "[AI-Stack] ERROR: $*" >&2; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_deps() {
    info "Checking prerequisites..."
    command -v docker  >/dev/null 2>&1 || die "Docker is not installed. See https://docs.docker.com/get-docker/"
    command -v docker  >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
        || die "Docker Compose plugin not found. See https://docs.docker.com/compose/install/"

    if $GPU; then
        command -v nvidia-smi >/dev/null 2>&1 \
            || warn "nvidia-smi not found — GPU support may not work"
        if $GH200; then
            docker run --rm --gpus all --platform linux/arm64 \
                nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1 \
                || warn "GH200 GPU passthrough test failed — check nvidia-container-toolkit and ARM64 runtime"
        else
            docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1 \
                || warn "GPU passthrough test failed — check nvidia-container-toolkit"
        fi
    fi
    success "Prerequisites OK"
}

# ── .env setup ────────────────────────────────────────────────────────────────
setup_env() {
    cd "$ROOT_DIR"
    if [[ -f .env ]]; then
        info ".env already exists — skipping copy"
        return
    fi
    cp .env.example .env
    info ".env created from .env.example"

    # Generate random secrets
    if command -v openssl >/dev/null 2>&1; then
        LITELLM_KEY="sk-$(openssl rand -hex 16)"
        WEBUI_KEY="$(openssl rand -hex 32)"
        PG_PASS="$(openssl rand -hex 16)"

        sed -i "s|LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${LITELLM_KEY}|" .env
        sed -i "s|WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=${WEBUI_KEY}|" .env
        sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASS}|" .env
        success "Random secrets generated in .env"
    else
        warn "openssl not found — default placeholder secrets left in .env. Change them before exposing to the internet."
    fi
}

# ── Build & start ─────────────────────────────────────────────────────────────
start_stack() {
    cd "$ROOT_DIR"
    info "Building images (this will take a few minutes on first run)..."

    if $GH200; then
        info "Starting with GH200 Grace Hopper support..."
        docker compose -f docker-compose.yml -f docker-compose.gh200.yml up -d --build
    elif $GPU; then
        info "Starting with GPU support..."
        docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --build
    else
        docker compose up -d --build
    fi

    success "All services started"
}

# ── Wait for healthy ──────────────────────────────────────────────────────────
wait_healthy() {
    info "Waiting for Open WebUI to become available..."
    PORT=$(grep "^HOST_PORT=" "$ROOT_DIR/.env" | cut -d= -f2)
    PORT="${PORT:-80}"
    MAX=60
    for i in $(seq 1 $MAX); do
        if curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; then
            success "Stack is up!"
            break
        fi
        if [[ $i -eq $MAX ]]; then
            warn "Timed out waiting for health check. Check logs: docker compose logs"
            return
        fi
        sleep 5
    done
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    PORT=$(grep "^HOST_PORT=" "$ROOT_DIR/.env" | cut -d= -f2)
    PORT="${PORT:-80}"
    echo ""
    echo "══════════════════════════════════════════════"
    echo "  AI Stack is running!"
    echo ""
    echo "  Open WebUI  →  http://localhost:${PORT}"
    echo "  LiteLLM API →  http://localhost:${PORT}/litellm/v1"
    echo "  ComfyUI     →  http://localhost:${PORT}/comfyui"
    echo ""
    echo "  Logs:   docker compose logs -f"
    echo "  Stop:   docker compose down"
    echo "  Update: bash scripts/update.sh"
    echo "══════════════════════════════════════════════"
    echo ""
    echo "  Next steps:"
    echo "  1. Edit .env and add your API keys"
    echo "  2. Restart: docker compose up -d"
    echo "  3. Open http://localhost:${PORT} and create your admin account"
    if $GH200; then
        echo ""
        echo "  GH200 tip: start vLLM for high-throughput local inference:"
        echo "    docker compose -f docker-compose.yml -f docker-compose.gh200.yml --profile vllm up -d --build"
        echo ""
        echo "  Download models for ComfyUI:"
        echo "    bash scripts/download-models.sh sd15"
    elif $GPU; then
        echo ""
        echo "  GPU tip: download a model into ComfyUI:"
        echo "    docker exec -it ai-comfyui bash"
        echo "    wget -P models/checkpoints <civitai/huggingface-model-url>"
    fi
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
check_deps
setup_env
start_stack
wait_healthy
print_summary
