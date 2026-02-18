#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — update all services to latest images
# Usage: bash scripts/update.sh [--gpu]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
GPU=false

for arg in "$@"; do
    case $arg in --gpu) GPU=true ;; esac
done

cd "$ROOT_DIR"

echo "[AI-Stack] Pulling latest images..."
docker compose pull --ignore-pull-failures

echo "[AI-Stack] Rebuilding ComfyUI..."
if $GPU; then
    docker compose -f docker-compose.yml -f docker-compose.gpu.yml build --no-cache comfyui
    docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
else
    docker compose build --no-cache comfyui
    docker compose up -d
fi

echo "[AI-Stack] Update complete. Running containers:"
docker compose ps
