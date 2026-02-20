#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# GH200 Bare-Metal Stack — no Docker required
#
# Installs CUDA toolkit, vLLM, Ollama, and ComfyUI directly on the host.
# Designed for NVIDIA GH200 (96 GB HBM3) on either ARM64 or x86_64 hosts.
#
# Prerequisites:
#   - NVIDIA driver 550+ installed and working (nvidia-smi shows the GPU)
#   - Ubuntu 22.04 or 24.04
#   - Root access
#
# Usage:
#   sudo bash scripts/setup-gh200-bare.sh
#
# After install, start services with:
#   systemctl start ollama
#   vllm serve <model> --host 0.0.0.0 --port 8000
#   cd /opt/ComfyUI && python3 main.py --listen 0.0.0.0 --bf16-unet --bf16-vae
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

info()    { echo "[Bare-Metal]  $*"; }
success() { echo "[Bare-Metal] ✓ $*"; }
warn()    { echo "[Bare-Metal] ! $*" >&2; }
die()     { echo "[Bare-Metal] ERROR: $*" >&2; exit 1; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo bash $0)"
fi

# ── GPU check ────────────────────────────────────────────────────────────────
if ! command -v nvidia-smi &>/dev/null; then
    die "nvidia-smi not found. Install the NVIDIA driver first:
    sudo bash scripts/install-cuda-gh200.sh"
fi

if ! nvidia-smi &>/dev/null; then
    die "nvidia-smi can't access the GPU. Reboot or check driver installation."
fi

DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
GPU_MEM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)"
info "GPU: ${GPU_NAME} (${GPU_MEM}), Driver: ${DRIVER_VER}"

ARCH="$(uname -m)"
info "Architecture: ${ARCH}"

# ── OS detection ─────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
else
    die "Cannot detect OS"
fi
info "OS: ${PRETTY_NAME}"

# ── Base packages ────────────────────────────────────────────────────────────
info "Installing base packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    curl \
    wget \
    zstd \
    ca-certificates

# ─────────────────────────────────────────────────────────────────────────────
#  1. CUDA TOOLKIT
# ─────────────────────────────────────────────────────────────────────────────
install_cuda_toolkit() {
    if command -v nvcc &>/dev/null; then
        local NVCC_VER
        NVCC_VER="$(nvcc --version | grep 'release' | sed 's/.*release //' | sed 's/,.*//')"
        success "CUDA toolkit already installed: nvcc ${NVCC_VER}"
        return 0
    fi

    info "Installing CUDA toolkit..."

    # Try NVIDIA's official repo first (gives CUDA 12.4 matching the driver)
    local CUDA_DISTRO="ubuntu${VERSION_ID/./}"
    local CUDA_REPO_ARCH
    case "$ARCH" in
        aarch64) CUDA_REPO_ARCH="sbsa" ;;
        x86_64)  CUDA_REPO_ARCH="x86_64" ;;
        *)       CUDA_REPO_ARCH="x86_64" ;;
    esac

    local CUDA_KEYRING="cuda-keyring_1.1-1_all.deb"
    local KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/${CUDA_REPO_ARCH}/${CUDA_KEYRING}"

    if curl -fsSL --max-time 15 "$KEYRING_URL" -o "/tmp/$CUDA_KEYRING" 2>/dev/null; then
        info "Using NVIDIA's official CUDA 12.4 repository..."
        dpkg -i "/tmp/$CUDA_KEYRING"
        rm -f "/tmp/$CUDA_KEYRING"
        apt-get update -y
        apt-get install -y --no-install-recommends cuda-toolkit-12-4
    else
        warn "NVIDIA repo unreachable — falling back to Ubuntu's CUDA toolkit package"
        apt-get install -y --no-install-recommends nvidia-cuda-toolkit
    fi

    # Set up PATH
    if [[ -d /usr/local/cuda-12.4 ]]; then
        CUDA_HOME="/usr/local/cuda-12.4"
    elif [[ -d /usr/local/cuda ]]; then
        CUDA_HOME="/usr/local/cuda"
    else
        CUDA_HOME="/usr"
    fi

    if ! grep -q 'cuda' /etc/profile.d/cuda.sh 2>/dev/null; then
        cat > /etc/profile.d/cuda.sh << ENVEOF
export PATH=${CUDA_HOME}/bin\${PATH:+:\$PATH}
export LD_LIBRARY_PATH=${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
ENVEOF
        chmod 644 /etc/profile.d/cuda.sh
    fi
    export PATH="${CUDA_HOME}/bin${PATH:+:$PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    success "CUDA toolkit installed ($(nvcc --version 2>/dev/null | grep release | sed 's/.*release //' | sed 's/,.*//' || echo 'check nvcc'))"
}

# ─────────────────────────────────────────────────────────────────────────────
#  2. vLLM
# ─────────────────────────────────────────────────────────────────────────────
install_vllm() {
    if python3 -c "import vllm; print(vllm.__version__)" &>/dev/null; then
        local VER
        VER="$(python3 -c 'import vllm; print(vllm.__version__)')"
        success "vLLM already installed: ${VER}"
        return 0
    fi

    info "Installing vLLM (includes PyTorch + CUDA runtime)..."
    info "This downloads ~5 GB — may take a few minutes..."

    # Fix common issue: system-managed 'packaging' can block pip
    pip3 install packaging --force-reinstall --no-deps --ignore-installed 2>/dev/null || true

    pip3 install vllm

    local VER
    VER="$(python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo 'unknown')"
    success "vLLM ${VER} installed (with PyTorch + CUDA runtime)"
}

# ─────────────────────────────────────────────────────────────────────────────
#  3. OLLAMA
# ─────────────────────────────────────────────────────────────────────────────
install_ollama() {
    if command -v ollama &>/dev/null; then
        success "Ollama already installed"
        return 0
    fi

    info "Installing Ollama..."

    # Try the official install script first
    if curl -fsSL --max-time 15 https://ollama.com/install.sh -o /tmp/ollama-install.sh 2>/dev/null; then
        info "Using official Ollama installer..."
        bash /tmp/ollama-install.sh
        rm -f /tmp/ollama-install.sh
    else
        # Fallback: download from GitHub releases
        info "ollama.com unreachable — downloading from GitHub releases..."
        local RELEASE_JSON
        RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest)"
        local TAG
        TAG="$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")"

        local OLLAMA_ARCH
        case "$ARCH" in
            aarch64) OLLAMA_ARCH="arm64" ;;
            x86_64)  OLLAMA_ARCH="amd64" ;;
            *)       die "Unsupported arch for Ollama: $ARCH" ;;
        esac

        local TARBALL="ollama-linux-${OLLAMA_ARCH}.tar.zst"
        local URL="https://github.com/ollama/ollama/releases/download/${TAG}/${TARBALL}"

        info "Downloading Ollama ${TAG}..."
        curl -fsSL "$URL" -o "/tmp/${TARBALL}"

        apt-get install -y --no-install-recommends zstd 2>/dev/null || true
        mkdir -p /tmp/ollama-extract
        tar --zstd -xf "/tmp/${TARBALL}" -C /tmp/ollama-extract

        cp /tmp/ollama-extract/bin/ollama /usr/local/bin/ollama
        chmod +x /usr/local/bin/ollama
        [[ -d /tmp/ollama-extract/lib ]] && cp -r /tmp/ollama-extract/lib/* /usr/local/lib/ && ldconfig

        rm -rf "/tmp/${TARBALL}" /tmp/ollama-extract
    fi

    # Create ollama systemd service if not already present
    if [[ ! -f /etc/systemd/system/ollama.service ]] && command -v systemctl &>/dev/null; then
        # Create ollama user if it doesn't exist
        id -u ollama &>/dev/null || useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama 2>/dev/null || true
        usermod -aG render ollama 2>/dev/null || true
        usermod -aG video ollama 2>/dev/null || true

        cat > /etc/systemd/system/ollama.service << 'SVCEOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_HOST=0.0.0.0"

[Install]
WantedBy=default.target
SVCEOF
        systemctl daemon-reload
        info "Ollama systemd service created (start with: systemctl start ollama)"
    fi

    success "Ollama $(ollama --version 2>&1 | grep -oP '[\d.]+' | head -1 || echo '') installed"
}

# ─────────────────────────────────────────────────────────────────────────────
#  4. COMFYUI
# ─────────────────────────────────────────────────────────────────────────────
install_comfyui() {
    local COMFYUI_DIR="/opt/ComfyUI"

    if [[ -d "$COMFYUI_DIR" ]] && [[ -f "$COMFYUI_DIR/main.py" ]]; then
        info "ComfyUI already cloned at ${COMFYUI_DIR} — updating..."
        cd "$COMFYUI_DIR" && git pull --ff-only 2>/dev/null || true
    else
        info "Cloning ComfyUI..."
        git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
    fi

    info "Installing ComfyUI dependencies..."
    pip3 install -r "$COMFYUI_DIR/requirements.txt"

    # Create model directories
    mkdir -p "$COMFYUI_DIR/models/"{checkpoints,vae,clip,loras,upscale_models,embeddings,controlnet}

    # Create a convenience systemd service
    if [[ ! -f /etc/systemd/system/comfyui.service ]] && command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/comfyui.service << SVCEOF
[Unit]
Description=ComfyUI Image Generation
After=network.target

[Service]
Type=simple
WorkingDirectory=${COMFYUI_DIR}
ExecStart=/usr/bin/python3 ${COMFYUI_DIR}/main.py --listen 0.0.0.0 --port 8188 --bf16-unet --bf16-vae
Restart=on-failure
RestartSec=5
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload
        info "ComfyUI systemd service created (start with: systemctl start comfyui)"
    fi

    success "ComfyUI installed at ${COMFYUI_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  5. VERIFY
# ─────────────────────────────────────────────────────────────────────────────
verify() {
    info "Verifying installation..."

    local ALL_OK=true

    # CUDA
    if command -v nvcc &>/dev/null; then
        success "nvcc: $(nvcc --version 2>/dev/null | grep release | sed 's/.*release //' | sed 's/,.*//')"
    else
        warn "nvcc not in PATH"
        ALL_OK=false
    fi

    # PyTorch + CUDA
    if python3 -c "import torch; assert torch.cuda.is_available()" &>/dev/null; then
        local TORCH_VER GPU_NAME_PY
        TORCH_VER="$(python3 -c 'import torch; print(torch.__version__)')"
        GPU_NAME_PY="$(python3 -c 'import torch; print(torch.cuda.get_device_name(0))')"
        success "PyTorch ${TORCH_VER} — GPU: ${GPU_NAME_PY}"
    else
        warn "PyTorch CUDA not available (may work after reboot/PATH fix)"
        ALL_OK=false
    fi

    # vLLM
    if python3 -c "import vllm" &>/dev/null; then
        success "vLLM $(python3 -c 'import vllm; print(vllm.__version__)')"
    else
        warn "vLLM import failed"
        ALL_OK=false
    fi

    # Ollama
    if command -v ollama &>/dev/null; then
        success "Ollama installed"
    else
        warn "Ollama not found"
        ALL_OK=false
    fi

    # ComfyUI
    if [[ -f /opt/ComfyUI/main.py ]]; then
        success "ComfyUI at /opt/ComfyUI"
    else
        warn "ComfyUI not found"
        ALL_OK=false
    fi

    $ALL_OK && success "All components verified!" || warn "Some checks failed — see above"
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  GH200 Bare-Metal Stack Setup"
echo "  GPU:  ${GPU_NAME} (${GPU_MEM})"
echo "  Arch: ${ARCH}"
echo "  OS:   ${PRETTY_NAME}"
echo "══════════════════════════════════════════════════════════════"
echo ""

install_cuda_toolkit
install_vllm
install_ollama
install_comfyui
verify

IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Bare-Metal Setup Complete!"
echo ""
echo "  Start services:"
echo "    systemctl start ollama"
echo "    ollama pull llama3.2"
echo ""
echo "    vllm serve meta-llama/Llama-3.2-3B-Instruct \\"
echo "      --host 0.0.0.0 --port 8000 --dtype bfloat16"
echo ""
echo "    systemctl start comfyui"
echo "    # or manually:"
echo "    cd /opt/ComfyUI && python3 main.py --listen 0.0.0.0 --bf16-unet --bf16-vae"
echo ""
echo "  URLs (after starting):"
echo "    Ollama   →  http://${IP}:11434"
echo "    vLLM     →  http://${IP}:8000"
echo "    ComfyUI  →  http://${IP}:8188"
echo ""
echo "  To start over from scratch, re-run:"
echo "    sudo bash scripts/setup-gh200-bare.sh"
echo "══════════════════════════════════════════════════════════════"
echo ""
