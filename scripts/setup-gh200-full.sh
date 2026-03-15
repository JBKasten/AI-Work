#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# GH200 Full Stack Setup — paste this into the GH200 terminal
# Sets up CUDA, Docker, clones the repo, builds, and configures accounts
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_URL="https://github.com/JBKasten/AI-Work.git"
BRANCH="claude/install-cuda-gh200-9b72w"
INSTALL_DIR="/root/ai-stack"

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@local.host}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 16)}"

# Minimal bootstrap logging (lib.sh not available until repo is cloned)
info()    { echo "[Setup]  $*"; }
success() { echo "[Setup] ✓ $*"; }
die()     { echo "[Setup] ERROR: $*" >&2; exit 1; }

banner() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    for line in "$@"; do echo "  $line"; done
    echo "══════════════════════════════════════════════════════════════"
    echo ""
}

banner \
    "GH200 Full Stack Setup" \
    "Email:  ${ADMIN_EMAIL}" \
    "Branch: ${BRANCH}"

# ── Step 1: Clone the repo ─────────────────────────────────────────────────
info "Cloning repo..."
apt-get update -y && apt-get install -y git
if [[ -d "$INSTALL_DIR" ]]; then
    info "Directory exists — pulling latest..."
    cd "$INSTALL_DIR"
    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
else
    git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi
success "Repo ready at $INSTALL_DIR"

# Now source lib.sh for the rest
LOG_PREFIX="Setup"
source scripts/lib.sh

# ── Step 2: Run CUDA + Docker installer ────────────────────────────────────
info "Running GH200 CUDA/Docker installer..."
bash scripts/install-cuda-gh200.sh

# ── Check if nvidia-smi works (open kernel modules may need a reboot) ──────
if ! nvidia-smi &>/dev/null; then
    if dpkg -l "nvidia-kernel-open-${NVIDIA_DRIVER_VERSION}" 2>/dev/null | grep -q '^ii'; then
        banner \
            "REBOOT REQUIRED" \
            "" \
            "The NVIDIA open kernel modules have been installed but" \
            "require a reboot to activate. The GH200 GPU will not" \
            "work until you reboot." \
            "" \
            "After reboot, re-run this script:" \
            "  cd ${INSTALL_DIR} && bash scripts/setup-gh200-full.sh" \
            "" \
            "Or reboot now:" \
            "  sudo reboot"
        exit 0
    fi
fi

# ── Step 3: Create .env with credentials ───────────────────────────────────
info "Configuring .env..."
cp -n .env.example .env 2>/dev/null || true

LITELLM_KEY="sk-$(openssl rand -hex 16)"
WEBUI_KEY="$(openssl rand -hex 32)"
PG_PASS="$(openssl rand -hex 16)"

sed -i "s|LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${LITELLM_KEY}|" .env
sed -i "s|WEBUI_SECRET_KEY=.*|WEBUI_SECRET_KEY=${WEBUI_KEY}|" .env
sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASS}|" .env
sed -i "s|DEFAULT_ADMIN_EMAIL=.*|DEFAULT_ADMIN_EMAIL=${ADMIN_EMAIL}|" .env
sed -i "s|DEFAULT_ADMIN_PASSWORD=.*|DEFAULT_ADMIN_PASSWORD=${ADMIN_PASSWORD}|" .env
sed -i "s|COMFYUI_ARGS=.*|COMFYUI_ARGS=--listen 0.0.0.0 --port 8188 --bf16-unet --bf16-vae|" .env

success ".env configured (admin: ${ADMIN_EMAIL})"

# ── Step 4: Build and start with GH200 overrides ──────────────────────────
info "Building and starting stack (GH200 mode)..."
docker compose -f docker-compose.yml -f docker-compose.gh200.yml up -d --build

# ── Step 5: Wait for services ──────────────────────────────────────────────
info "Waiting for services to come up..."
MAX=90
for i in $(seq 1 $MAX); do
    if curl -sf http://localhost:80/health >/dev/null 2>&1; then
        success "Open WebUI is healthy!"
        break
    fi
    if [[ $i -eq $MAX ]]; then
        warn "Timed out. Check: docker compose logs"
    fi
    sleep 5
done

# ── Step 6: Download models ───────────────────────────────────────────────
info "Downloading starter models (SD 1.5 + upscalers)..."
bash scripts/download-models.sh sd15 || warn "Model download had issues — you can re-run later"
bash scripts/download-models.sh upscalers || warn "Upscaler download had issues — you can re-run later"

# ── Done ──────────────────────────────────────────────────────────────────
IP="$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"

banner \
    "GH200 Stack is LIVE!" \
    "" \
    "Open WebUI  →  http://${IP}" \
    "ComfyUI     →  http://${IP}/comfyui" \
    "LiteLLM API →  http://${IP}/litellm/v1" \
    "" \
    "Login:" \
    "  Email:    ${ADMIN_EMAIL}" \
    "  Password: (same as server password)" \
    "" \
    "Enable MFA (YubiKey + TOTP):" \
    "  bash scripts/setup-mfa.sh" \
    "" \
    "To download FLUX models later:" \
    "  bash scripts/download-models.sh flux-schnell" \
    "" \
    "Logs:  docker compose logs -f" \
    "Stop:  docker compose down"
