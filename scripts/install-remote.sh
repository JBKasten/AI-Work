#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — Remote server installer
# Copies the project to a remote server via rsync/scp and runs the install.
#
# Usage:
#   bash scripts/install-remote.sh <user@host> [--gpu|--gh200]
#
# Examples:
#   bash scripts/install-remote.sh root@192.168.1.100 --gh200
#   bash scripts/install-remote.sh ubuntu@myserver.com --gpu
#   bash scripts/install-remote.sh root@10.0.0.5
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
REMOTE_DIR="/opt/ai-stack"

SSH_TARGET="${1:-}"
shift || true
INSTALL_FLAGS="$*"

info()    { echo "[Remote]  $*"; }
success() { echo "[Remote] ✓ $*"; }
warn()    { echo "[Remote] ! $*" >&2; }
die()     { echo "[Remote] ERROR: $*" >&2; exit 1; }

[[ -z "$SSH_TARGET" ]] && die "Usage: bash scripts/install-remote.sh <user@host> [--gpu|--gh200]"

# ── Test SSH connectivity ────────────────────────────────────────────────────
info "Testing SSH connection to ${SSH_TARGET}..."
ssh -o ConnectTimeout=10 -o BatchMode=no "$SSH_TARGET" "echo ok" >/dev/null 2>&1 \
    || die "Cannot SSH to ${SSH_TARGET}. Check credentials and connectivity."
success "SSH connection OK"

# ── Check Docker on remote ───────────────────────────────────────────────────
info "Checking Docker on remote host..."
ssh "$SSH_TARGET" "command -v docker >/dev/null 2>&1" \
    || die "Docker is not installed on ${SSH_TARGET}. Install it first: https://docs.docker.com/get-docker/"
ssh "$SSH_TARGET" "docker compose version >/dev/null 2>&1" \
    || die "Docker Compose plugin not found on ${SSH_TARGET}. See https://docs.docker.com/compose/install/"
success "Docker OK on remote"

# ── Sync project files ───────────────────────────────────────────────────────
info "Syncing project to ${SSH_TARGET}:${REMOTE_DIR}..."
ssh "$SSH_TARGET" "mkdir -p ${REMOTE_DIR}"

if command -v rsync >/dev/null 2>&1; then
    rsync -az --delete \
        --exclude '.git' \
        --exclude '.env' \
        --exclude 'node_modules' \
        --exclude '__pycache__' \
        "$ROOT_DIR/" "${SSH_TARGET}:${REMOTE_DIR}/"
else
    # Fallback to scp if rsync is not available
    warn "rsync not found, falling back to scp (slower)"
    scp -r "$ROOT_DIR/"* "${SSH_TARGET}:${REMOTE_DIR}/"
fi
success "Project synced to ${REMOTE_DIR}"

# ── Run install on remote ────────────────────────────────────────────────────
info "Running install on ${SSH_TARGET}..."
ssh -t "$SSH_TARGET" "cd ${REMOTE_DIR} && bash scripts/install.sh ${INSTALL_FLAGS}"

# ── Print access info ────────────────────────────────────────────────────────
HOST=$(echo "$SSH_TARGET" | cut -d@ -f2)
echo ""
echo "══════════════════════════════════════════════"
echo "  Remote install complete!"
echo ""
echo "  Open WebUI  →  http://${HOST}"
echo "  LiteLLM API →  http://${HOST}/litellm/v1"
echo "  ComfyUI     →  http://${HOST}/comfyui"
echo ""
echo "  SSH in:     ssh ${SSH_TARGET}"
echo "  Logs:       ssh ${SSH_TARGET} 'cd ${REMOTE_DIR} && docker compose logs -f'"
echo ""
echo "  Next steps:"
echo "  1. SSH in and edit ${REMOTE_DIR}/.env to add API keys"
echo "  2. Restart: docker compose up -d"
echo "  3. Open http://${HOST} and create your admin account"
echo "══════════════════════════════════════════════"
