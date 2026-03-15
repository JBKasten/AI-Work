#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — Shared library
# Source this file from any script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib.sh"
# ─────────────────────────────────────────────────────────────────────────────

# Prevent double-sourcing
[[ -n "${_LIB_SH_LOADED:-}" ]] && return 0
_LIB_SH_LOADED=1

# ── Paths ────────────────────────────────────────────────────────────────────
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$LIB_DIR")"

# ── Load config.env (centralized versions & URLs) ────────────────────────────
if [[ -f "${ROOT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/config.env"
fi

# ── Logging ──────────────────────────────────────────────────────────────────
# Set LOG_PREFIX in your script before sourcing lib.sh to customise.
LOG_PREFIX="${LOG_PREFIX:-AI-Stack}"

info()    { echo "[${LOG_PREFIX}]  $*"; }
success() { echo "[${LOG_PREFIX}] ✓ $*"; }
warn()    { echo "[${LOG_PREFIX}] ! $*" >&2; }
die()     { echo "[${LOG_PREFIX}] ERROR: $*" >&2; exit 1; }

# ── Root check ───────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo bash $0)"
}

# ── Architecture detection ───────────────────────────────────────────────────
detect_arch() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        aarch64) CUDA_REPO_ARCH="sbsa";  OLLAMA_ARCH="arm64"; DOCKER_ARCH="arm64" ;;
        x86_64)  CUDA_REPO_ARCH="x86_64"; OLLAMA_ARCH="amd64"; DOCKER_ARCH="amd64" ;;
        *)       die "Unsupported architecture: $ARCH" ;;
    esac
    export ARCH CUDA_REPO_ARCH OLLAMA_ARCH DOCKER_ARCH
}

# ── OS detection ─────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO="$ID"
        DISTRO_VERSION="$VERSION_ID"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
        DISTRO_PRETTY="${PRETTY_NAME}"
    else
        die "Cannot detect OS — /etc/os-release not found"
    fi
    export DISTRO DISTRO_VERSION DISTRO_CODENAME DISTRO_PRETTY
}

# ── GPU detection ────────────────────────────────────────────────────────────
detect_gpu() {
    if ! command -v nvidia-smi &>/dev/null; then
        GPU_AVAILABLE=false
        return
    fi
    if ! nvidia-smi &>/dev/null; then
        GPU_AVAILABLE=false
        return
    fi
    GPU_AVAILABLE=true
    GPU_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    GPU_MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)"
    export GPU_AVAILABLE GPU_DRIVER GPU_NAME GPU_MEM
}

# ── apt with retry ───────────────────────────────────────────────────────────
apt_retry() {
    local attempt
    for attempt in 1 2 3; do
        if apt-get "$@"; then
            return 0
        fi
        warn "apt-get $1 failed (attempt $attempt/3), retrying in 3s..."
        sleep 3
    done
    die "apt-get $1 failed after 3 attempts"
}

# ── Download with retry ─────────────────────────────────────────────────────
download() {
    local url="$1" dest="$2" attempt
    for attempt in 1 2 3; do
        if curl -fsSL --max-time 60 "$url" -o "$dest" 2>/dev/null; then
            return 0
        fi
        warn "Download failed (attempt $attempt/3): $url"
        sleep $((attempt * 2))
    done
    return 1
}

# ── Get public IP ────────────────────────────────────────────────────────────
get_public_ip() {
    curl -s --max-time 5 ifconfig.me 2>/dev/null \
        || hostname -I 2>/dev/null | awk '{print $1}' \
        || echo "localhost"
}

# ── Check if a command exists ────────────────────────────────────────────────
has_cmd() { command -v "$1" &>/dev/null; }

# ── Idempotent systemd service creator ───────────────────────────────────────
install_systemd_service() {
    local name="$1" content="$2"
    local path="/etc/systemd/system/${name}.service"
    if [[ -f "$path" ]]; then
        info "Systemd service ${name} already exists — skipping"
        return 0
    fi
    if ! has_cmd systemctl; then
        warn "systemctl not found — skipping ${name} service creation"
        return 0
    fi
    echo "$content" > "$path"
    systemctl daemon-reload
    info "Created systemd service: ${name} (start with: systemctl start ${name})"
}

# ── Banner helper ────────────────────────────────────────────────────────────
banner() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    for line in "$@"; do
        echo "  $line"
    done
    echo "══════════════════════════════════════════════════════════════"
    echo ""
}
