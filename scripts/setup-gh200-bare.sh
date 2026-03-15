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
#   sudo bash scripts/setup-gh200-bare.sh              # install all
#   sudo bash scripts/setup-gh200-bare.sh --only cuda,vllm   # selective
#   sudo bash scripts/setup-gh200-bare.sh --only ollama       # just Ollama
#
# Components: cuda, vllm, ollama, comfyui
#
# After install, start services with:
#   systemctl start ollama
#   vllm serve <model> --host 0.0.0.0 --port 8000
#   cd /opt/ComfyUI && python3 main.py --listen 0.0.0.0 --bf16-unet --bf16-vae
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOG_PREFIX="Bare-Metal"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_root

# ── Parse arguments ──────────────────────────────────────────────────────────
ONLY_COMPONENTS=""
for arg in "$@"; do
    case "$arg" in
        --only=*) ONLY_COMPONENTS="${arg#--only=}" ;;
        --only)   shift_next=true ;;
        *)
            if [[ "${shift_next:-}" == "true" ]]; then
                ONLY_COMPONENTS="$arg"
                shift_next=false
            fi
            ;;
    esac
done

should_install() {
    local component="$1"
    [[ -z "$ONLY_COMPONENTS" ]] && return 0
    echo ",$ONLY_COMPONENTS," | grep -q ",$component,"
}

# ── GPU check ────────────────────────────────────────────────────────────────
if ! has_cmd nvidia-smi; then
    die "nvidia-smi not found. Install the NVIDIA driver first:
    sudo bash scripts/install-cuda-gh200.sh"
fi

if ! nvidia-smi &>/dev/null; then
    die "nvidia-smi can't access the GPU. Reboot or check driver installation."
fi

detect_arch
detect_os
detect_gpu

info "GPU: ${GPU_NAME} (${GPU_MEM}), Driver: ${GPU_DRIVER}"
info "Architecture: ${ARCH}"
info "OS: ${DISTRO_PRETTY}"

# ── Base packages ────────────────────────────────────────────────────────────
info "Installing base packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
    build-essential python3 python3-pip python3-venv python3-dev \
    git curl wget zstd ca-certificates

# ─────────────────────────────────────────────────────────────────────────────
#  1. CUDA TOOLKIT
# ─────────────────────────────────────────────────────────────────────────────
install_cuda_toolkit() {
    if has_cmd nvcc; then
        local NVCC_VER
        NVCC_VER="$(nvcc --version | grep 'release' | sed 's/.*release //' | sed 's/,.*//')"
        success "CUDA toolkit already installed: nvcc ${NVCC_VER}"
        return 0
    fi

    info "Installing CUDA toolkit..."

    local CUDA_DISTRO="ubuntu${VERSION_ID/./}"
    local CUDA_KEYRING="cuda-keyring_${CUDA_KEYRING_VERSION}_all.deb"
    local KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/${CUDA_REPO_ARCH}/${CUDA_KEYRING}"

    if download "$KEYRING_URL" "/tmp/$CUDA_KEYRING"; then
        info "Using NVIDIA's official CUDA ${CUDA_VERSION} repository..."
        dpkg -i "/tmp/$CUDA_KEYRING"
        rm -f "/tmp/$CUDA_KEYRING"
        apt-get update -y
        apt-get install -y --no-install-recommends "cuda-toolkit-${CUDA_VERSION//./-}"
    else
        warn "NVIDIA repo unreachable — falling back to Ubuntu's CUDA toolkit package"
        apt-get install -y --no-install-recommends nvidia-cuda-toolkit
    fi

    # Set up PATH
    local CUDA_HOME
    if [[ -d "/usr/local/cuda-${CUDA_VERSION}" ]]; then
        CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
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

    pip3 install packaging --force-reinstall --no-deps --ignore-installed 2>/dev/null || true
    pip3 install "${VLLM_PIP_PACKAGE}"

    local VER
    VER="$(python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo 'unknown')"
    success "vLLM ${VER} installed (with PyTorch + CUDA runtime)"
}

# ─────────────────────────────────────────────────────────────────────────────
#  3. OLLAMA
# ─────────────────────────────────────────────────────────────────────────────
install_ollama() {
    if has_cmd ollama; then
        success "Ollama already installed"
        return 0
    fi

    info "Installing Ollama..."

    if download "$OLLAMA_INSTALL_URL" /tmp/ollama-install.sh; then
        info "Using official Ollama installer..."
        bash /tmp/ollama-install.sh
        rm -f /tmp/ollama-install.sh
    else
        info "ollama.com unreachable — downloading from GitHub releases..."
        local RELEASE_JSON TAG
        RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${OLLAMA_GITHUB_REPO}/releases/latest")"
        TAG="$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")"

        local TARBALL="ollama-linux-${OLLAMA_ARCH}.tar.zst"
        local URL="https://github.com/${OLLAMA_GITHUB_REPO}/releases/download/${TAG}/${TARBALL}"

        info "Downloading Ollama ${TAG}..."
        curl -fsSL "$URL" -o "/tmp/${TARBALL}"

        mkdir -p /tmp/ollama-extract
        tar --zstd -xf "/tmp/${TARBALL}" -C /tmp/ollama-extract

        cp /tmp/ollama-extract/bin/ollama /usr/local/bin/ollama
        chmod +x /usr/local/bin/ollama
        [[ -d /tmp/ollama-extract/lib ]] && cp -r /tmp/ollama-extract/lib/* /usr/local/lib/ && ldconfig

        rm -rf "/tmp/${TARBALL}" /tmp/ollama-extract
    fi

    # Create ollama systemd service
    id -u ollama &>/dev/null || useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama 2>/dev/null || true
    usermod -aG render ollama 2>/dev/null || true
    usermod -aG video ollama 2>/dev/null || true

    install_systemd_service "ollama" '[Unit]
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
WantedBy=default.target'

    success "Ollama $(ollama --version 2>&1 | grep -oP '[\d.]+' | head -1 || echo '') installed"
}

# ─────────────────────────────────────────────────────────────────────────────
#  4. COMFYUI
# ─────────────────────────────────────────────────────────────────────────────
install_comfyui() {
    if [[ -d "$COMFYUI_INSTALL_DIR" ]] && [[ -f "$COMFYUI_INSTALL_DIR/main.py" ]]; then
        info "ComfyUI already cloned at ${COMFYUI_INSTALL_DIR} — updating..."
        cd "$COMFYUI_INSTALL_DIR" && git pull --ff-only 2>/dev/null || true
    else
        info "Cloning ComfyUI..."
        git clone --depth 1 "$COMFYUI_REPO" "$COMFYUI_INSTALL_DIR"
    fi

    info "Installing ComfyUI dependencies..."
    pip3 install -r "$COMFYUI_INSTALL_DIR/requirements.txt"

    mkdir -p "$COMFYUI_INSTALL_DIR/models/"{checkpoints,vae,clip,loras,upscale_models,embeddings,controlnet}

    install_systemd_service "comfyui" "[Unit]
Description=ComfyUI Image Generation
After=network.target

[Service]
Type=simple
WorkingDirectory=${COMFYUI_INSTALL_DIR}
ExecStart=/usr/bin/python3 ${COMFYUI_INSTALL_DIR}/main.py --listen 0.0.0.0 --port ${COMFYUI_PORT} --bf16-unet --bf16-vae
Restart=on-failure
RestartSec=5
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin\"

[Install]
WantedBy=multi-user.target"

    success "ComfyUI installed at ${COMFYUI_INSTALL_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  5. VERIFY
# ─────────────────────────────────────────────────────────────────────────────
verify() {
    info "Verifying installation..."
    local ALL_OK=true

    if has_cmd nvcc; then
        success "nvcc: $(nvcc --version 2>/dev/null | grep release | sed 's/.*release //' | sed 's/,.*//')"
    else
        warn "nvcc not in PATH"; ALL_OK=false
    fi

    if python3 -c "import torch; assert torch.cuda.is_available()" &>/dev/null; then
        success "PyTorch $(python3 -c 'import torch; print(torch.__version__)') — GPU: $(python3 -c 'import torch; print(torch.cuda.get_device_name(0))')"
    else
        warn "PyTorch CUDA not available (may work after reboot/PATH fix)"; ALL_OK=false
    fi

    if python3 -c "import vllm" &>/dev/null; then
        success "vLLM $(python3 -c 'import vllm; print(vllm.__version__)')"
    else
        warn "vLLM import failed"; ALL_OK=false
    fi

    if has_cmd ollama; then
        success "Ollama installed"
    else
        warn "Ollama not found"; ALL_OK=false
    fi

    if [[ -f "${COMFYUI_INSTALL_DIR}/main.py" ]]; then
        success "ComfyUI at ${COMFYUI_INSTALL_DIR}"
    else
        warn "ComfyUI not found"; ALL_OK=false
    fi

    $ALL_OK && success "All components verified!" || warn "Some checks failed — see above"
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$ONLY_COMPONENTS" ]]; then
    banner \
        "GH200 Bare-Metal Stack Setup (selective)" \
        "Components: ${ONLY_COMPONENTS}" \
        "GPU:  ${GPU_NAME} (${GPU_MEM})" \
        "Arch: ${ARCH}"
else
    banner \
        "GH200 Bare-Metal Stack Setup" \
        "GPU:  ${GPU_NAME} (${GPU_MEM})" \
        "Arch: ${ARCH}" \
        "OS:   ${DISTRO_PRETTY}"
fi

should_install cuda    && install_cuda_toolkit
should_install vllm    && install_vllm
should_install ollama  && install_ollama
should_install comfyui && install_comfyui
verify

IP="$(get_public_ip)"

banner \
    "Bare-Metal Setup Complete!" \
    "" \
    "Start services:" \
    "  systemctl start ollama" \
    "  ollama pull llama3.2" \
    "" \
    "  vllm serve meta-llama/Llama-3.2-3B-Instruct \\" \
    "    --host 0.0.0.0 --port ${VLLM_PORT} --dtype bfloat16" \
    "" \
    "  systemctl start comfyui" \
    "  # or manually:" \
    "  cd ${COMFYUI_INSTALL_DIR} && python3 main.py --listen 0.0.0.0 --bf16-unet --bf16-vae" \
    "" \
    "URLs (after starting):" \
    "  Ollama   →  http://${IP}:${OLLAMA_PORT}" \
    "  vLLM     →  http://${IP}:${VLLM_PORT}" \
    "  ComfyUI  →  http://${IP}:${COMFYUI_PORT}" \
    "" \
    "Selective install:" \
    "  sudo bash scripts/setup-gh200-bare.sh --only cuda,vllm" \
    "  sudo bash scripts/setup-gh200-bare.sh --only ollama"
