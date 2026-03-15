#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — one-shot install script
# Usage: bash scripts/install.sh [--gpu]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOG_PREFIX="AI-Stack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

GPU=false
for arg in "$@"; do
    case $arg in
        --gpu) GPU=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_deps() {
    info "Checking prerequisites..."
    has_cmd docker || die "Docker is not installed. See https://docs.docker.com/get-docker/"
    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose plugin not found. See https://docs.docker.com/compose/install/"

    if $GPU; then
        has_cmd nvidia-smi \
            || warn "nvidia-smi not found — GPU support may not work"
        docker run --rm --gpus all "${CUDA_TEST_IMAGE}" nvidia-smi >/dev/null 2>&1 \
            || warn "GPU passthrough test failed — check nvidia-container-toolkit"
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

    if has_cmd openssl; then
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

    if $GPU; then
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

    banner \
        "AI Stack is running!" \
        "" \
        "Open WebUI  →  http://localhost:${PORT}" \
        "LiteLLM API →  http://localhost:${PORT}/litellm/v1" \
        "ComfyUI     →  http://localhost:${PORT}/comfyui" \
        "" \
        "Logs:   docker compose logs -f" \
        "Stop:   docker compose down" \
        "Update: bash scripts/update.sh" \
        "" \
        "Next steps:" \
        "1. Edit .env and add your API keys" \
        "2. Restart: docker compose up -d" \
        "3. Open http://localhost:${PORT} and create your admin account" \
        "4. Enable MFA: bash scripts/setup-mfa.sh"
}

# ── Main ──────────────────────────────────────────────────────────────────────
check_deps
setup_env
start_stack
wait_healthy
print_summary
