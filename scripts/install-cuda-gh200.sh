#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# GH200 Grace Hopper — CUDA + Docker + nvidia-container-toolkit installer
#
# Prepares a bare Ubuntu 22.04/24.04 ARM64 GH200 host to run the AI Stack.
# Installs: NVIDIA driver 550, CUDA 12.4, Docker CE, nvidia-container-toolkit.
#
# Usage:
#   curl -fsSL <raw-url>/scripts/install-cuda-gh200.sh | bash
#   # or
#   sudo bash scripts/install-cuda-gh200.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOG_PREFIX="GH200-Setup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_root
detect_arch
detect_os

info "OS: $DISTRO $DISTRO_VERSION ($DISTRO_CODENAME)"

case "$DISTRO" in
    ubuntu)
        if [[ "$DISTRO_VERSION" != "22.04" && "$DISTRO_VERSION" != "24.04" ]]; then
            warn "Tested on Ubuntu 22.04 and 24.04. You have $DISTRO_VERSION — proceeding anyway."
        fi
        ;;
    *)
        warn "This script is written for Ubuntu. Detected $DISTRO — proceeding but YMMV."
        ;;
esac

# ── Install base packages ───────────────────────────────────────────────────
info "Installing base packages..."
apt_retry update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    software-properties-common dirmngr apt-transport-https

# ─────────────────────────────────────────────────────────────────────────────
#  1. NVIDIA DRIVER + CUDA TOOLKIT
# ─────────────────────────────────────────────────────────────────────────────
install_cuda() {
    local NEED_INSTALL=true
    local NEED_OPEN_MODULE_FIX=false

    if has_cmd nvidia-smi; then
        local DRIVER_VER
        DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" || true

        if [[ -n "$DRIVER_VER" ]]; then
            info "NVIDIA driver already installed and working: $DRIVER_VER"
            local MAJOR="${DRIVER_VER%%.*}"
            if [[ "$MAJOR" -ge ${NVIDIA_DRIVER_VERSION} ]]; then
                success "Driver $DRIVER_VER >= ${NVIDIA_DRIVER_VERSION} — OK"
                NEED_INSTALL=false
            else
                warn "Driver $DRIVER_VER is below ${NVIDIA_DRIVER_VERSION}. Upgrading..."
            fi
        else
            warn "nvidia-smi found but GPU not accessible"
            if dmesg 2>/dev/null | grep -q "self-hosted.*NVIDIA open kernel modules"; then
                warn "GH200 requires OPEN kernel modules — proprietary modules detected"
                NEED_OPEN_MODULE_FIX=true
            elif grep -q "self-hosted" /var/log/syslog 2>/dev/null; then
                warn "GH200 requires OPEN kernel modules — proprietary modules detected"
                NEED_OPEN_MODULE_FIX=true
            else
                warn "Driver may need a reboot or reinstall"
            fi
        fi
    else
        info "No NVIDIA driver detected — installing..."
    fi

    # Add NVIDIA CUDA repository
    local CUDA_DISTRO="ubuntu${DISTRO_VERSION/./}"
    info "Adding NVIDIA CUDA ${CUDA_VERSION} repository for ${ARCH} (${CUDA_DISTRO}/${CUDA_REPO_ARCH})..."
    local CUDA_KEYRING="cuda-keyring_${CUDA_KEYRING_VERSION}_all.deb"
    download \
        "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/${CUDA_REPO_ARCH}/$CUDA_KEYRING" \
        "/tmp/$CUDA_KEYRING" \
        || die "Failed to download CUDA keyring"
    dpkg -i "/tmp/$CUDA_KEYRING"
    rm -f "/tmp/$CUDA_KEYRING"
    apt_retry update -y

    local CUDA_PKG="cuda-toolkit-${CUDA_VERSION//./-}"
    local DRIVER_OPEN="nvidia-kernel-open-${NVIDIA_DRIVER_VERSION}"
    local DRIVER_PKG="nvidia-driver-${NVIDIA_DRIVER_VERSION}-open"

    if $NEED_OPEN_MODULE_FIX; then
        info "Switching from proprietary to OPEN kernel modules for GH200..."
        apt-get remove -y --purge "nvidia-kernel-source-${NVIDIA_DRIVER_VERSION}" 2>/dev/null || true
        apt-get install -y --no-install-recommends "$DRIVER_OPEN" "$CUDA_PKG"
        update-initramfs -u
        success "Open kernel modules installed — REBOOT REQUIRED"
    elif $NEED_INSTALL; then
        info "Installing CUDA ${CUDA_VERSION} toolkit and open driver ${NVIDIA_DRIVER_VERSION} for GH200..."
        apt-get install -y --no-install-recommends "$CUDA_PKG" "$DRIVER_OPEN" "$DRIVER_PKG"
        update-initramfs -u
    fi

    # Set up PATH and LD_LIBRARY_PATH
    local CUDA_HOME="/usr/local/cuda-${CUDA_VERSION}"
    if ! grep -q '/usr/local/cuda' /etc/profile.d/cuda.sh 2>/dev/null; then
        cat > /etc/profile.d/cuda.sh << ENVEOF
export PATH=${CUDA_HOME}/bin\${PATH:+:\$PATH}
export LD_LIBRARY_PATH=${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
ENVEOF
        chmod 644 /etc/profile.d/cuda.sh
    fi
    export PATH="${CUDA_HOME}/bin${PATH:+:$PATH}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    success "CUDA ${CUDA_VERSION} installed"
}

# ─────────────────────────────────────────────────────────────────────────────
#  2. DOCKER CE
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    if has_cmd docker; then
        success "Docker already installed: $(docker --version)"
        if docker compose version &>/dev/null; then
            success "Docker Compose plugin available"
            return 0
        else
            warn "Docker Compose plugin missing — installing..."
        fi
    else
        info "Docker not found — installing Docker CE..."
    fi

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        ${DISTRO_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt_retry update -y
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    success "Docker CE installed and running"

    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        info "Added $SUDO_USER to docker group (re-login to take effect)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  3. NVIDIA CONTAINER TOOLKIT
# ─────────────────────────────────────────────────────────────────────────────
install_nvidia_container_toolkit() {
    if dpkg -l | grep -q nvidia-container-toolkit 2>/dev/null; then
        success "nvidia-container-toolkit already installed"
    else
        info "Installing nvidia-container-toolkit..."
    fi

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg --yes

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt_retry update -y
    apt-get install -y --no-install-recommends nvidia-container-toolkit

    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    success "nvidia-container-toolkit installed and Docker configured"
}

# ─────────────────────────────────────────────────────────────────────────────
#  4. VERIFY
# ─────────────────────────────────────────────────────────────────────────────
verify() {
    info "Running GPU verification..."

    echo ""
    echo "── nvidia-smi ──────────────────────────────────────────────"
    if nvidia-smi; then
        echo ""
        echo "── Docker GPU passthrough test ─────────────────────────────"
        if docker run --rm --gpus all "${CUDA_TEST_IMAGE}" nvidia-smi; then
            success "Docker GPU passthrough works"
        else
            warn "Docker GPU passthrough failed. Try rebooting, then run:"
            warn "  docker run --rm --gpus all ${CUDA_TEST_IMAGE} nvidia-smi"
        fi
    else
        if dpkg -l "nvidia-kernel-open-${NVIDIA_DRIVER_VERSION}" 2>/dev/null | grep -q '^ii'; then
            warn "nvidia-smi failed — this is expected before reboot."
            warn "Open kernel modules are installed. Reboot to activate them:"
            warn "  sudo reboot"
        else
            die "nvidia-smi failed — driver installation may have failed"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
banner \
    "GH200 Grace Hopper — CUDA + Docker Setup" \
    "Target: NVIDIA driver ${NVIDIA_DRIVER_VERSION}+, CUDA ${CUDA_VERSION}, Docker CE," \
    "        nvidia-container-toolkit"

install_cuda
install_docker
install_nvidia_container_toolkit
verify

banner \
    "GH200 host setup complete!" \
    "" \
    "Next steps:" \
    "  cd $(pwd)" \
    "  bash scripts/install.sh --gpu" \
    "" \
    "Then start with GH200 overrides:" \
    "  docker compose -f docker-compose.yml \\" \
    "    -f docker-compose.gh200.yml up -d --build" \
    "" \
    "If nvidia-smi failed above, reboot first:" \
    "  sudo reboot"
