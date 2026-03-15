#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — update all services to latest images
# Usage: bash scripts/update.sh [--gpu] [--gh200]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOG_PREFIX="AI-Stack"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

GPU=false
GH200=false
for arg in "$@"; do
    case $arg in
        --gpu)   GPU=true ;;
        --gh200) GH200=true ;;
    esac
done

cd "$ROOT_DIR"

info "Pulling latest images..."
docker compose pull --ignore-pull-failures

info "Rebuilding ComfyUI..."
if $GH200; then
    docker compose -f docker-compose.yml -f docker-compose.gh200.yml build --no-cache comfyui
    docker compose -f docker-compose.yml -f docker-compose.gh200.yml up -d
elif $GPU; then
    docker compose -f docker-compose.yml -f docker-compose.gpu.yml build --no-cache comfyui
    docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
else
    docker compose build --no-cache comfyui
    docker compose up -d
fi

success "Update complete. Running containers:"
docker compose ps
