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
#   bash scripts/install-cuda-gh200.sh
#
# After this script finishes, run:
#   bash scripts/install.sh --gpu
#   # then bring up GH200 overrides:
#   docker compose -f docker-compose.yml -f docker-compose.gh200.yml up -d --build
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

info()    { echo "[GH200-Setup]  $*"; }
success() { echo "[GH200-Setup] ✓ $*"; }
warn()    { echo "[GH200-Setup] ! $*" >&2; }
die()     { echo "[GH200-Setup] ERROR: $*" >&2; exit 1; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo bash $0)"
fi

# ── Architecture check ───────────────────────────────────────────────────────
ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" ]]; then
    die "GH200 is ARM64 (aarch64). Detected architecture: $ARCH"
fi

info "Architecture: $ARCH — OK"

# ── OS detection ─────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO="$ID"
    DISTRO_VERSION="$VERSION_ID"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"
else
    die "Cannot detect OS — /etc/os-release not found"
fi

info "OS: $DISTRO $DISTRO_VERSION ($DISTRO_CODENAME)"

case "$DISTRO" in
    ubuntu)
        if [[ "$DISTRO_VERSION" != "22.04" && "$DISTRO_VERSION" != "24.04" ]]; then
            warn "Tested on Ubuntu 22.04 and 24.04. You have $DISTRO_VERSION — proceeding anyway."
        fi
        ;;
    *)
        warn "This script is written for Ubuntu. Detected $DISTRO — proceeding but your mileage may vary."
        ;;
esac

# ── Helper: apt retry ────────────────────────────────────────────────────────
apt_update() {
    local attempt
    for attempt in 1 2 3; do
        if apt-get update -y; then
            return 0
        fi
        warn "apt-get update failed (attempt $attempt/3), retrying..."
        sleep 3
    done
    die "apt-get update failed after 3 attempts"
}

# ── Install base packages ───────────────────────────────────────────────────
info "Installing base packages..."
apt_update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    dirmngr \
    apt-transport-https

# ─────────────────────────────────────────────────────────────────────────────
#  1. NVIDIA DRIVER + CUDA TOOLKIT
#
#  GH200 is a "self-hosted" GPU (integrated with Grace CPU, not standard PCIe)
#  and REQUIRES the open kernel modules (nvidia-kernel-open-550).
#  The proprietary (closed-source) modules will load but refuse to initialize,
#  resulting in "No devices were found" from nvidia-smi and dmesg errors:
#    NVRM: installed in this system is self-hosted, and requires
#    NVRM: use of the NVIDIA open kernel modules.
# ─────────────────────────────────────────────────────────────────────────────
install_cuda() {
    local NEED_INSTALL=true
    local NEED_OPEN_MODULE_FIX=false

    # Check if driver is installed and working
    if command -v nvidia-smi &>/dev/null; then
        local DRIVER_VER
        DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" || true

        if [[ -n "$DRIVER_VER" ]]; then
            info "NVIDIA driver already installed and working: $DRIVER_VER"
            local MAJOR="${DRIVER_VER%%.*}"
            if [[ "$MAJOR" -ge 550 ]]; then
                success "Driver $DRIVER_VER >= 550 — OK"
                NEED_INSTALL=false
            else
                warn "Driver $DRIVER_VER is below 550. Upgrading..."
            fi
        else
            # nvidia-smi exists but can't query GPU — likely closed-source module on GH200
            warn "nvidia-smi found but GPU not accessible"

            # Check dmesg for the telltale self-hosted message
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

    # Add NVIDIA CUDA repository (sbsa = server-base system architecture for ARM64)
    info "Adding NVIDIA CUDA 12.4 repository for ARM64 (sbsa)..."
    local CUDA_KEYRING="cuda-keyring_1.1-1_all.deb"
    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/sbsa/$CUDA_KEYRING" \
        -o "/tmp/$CUDA_KEYRING"
    dpkg -i "/tmp/$CUDA_KEYRING"
    rm -f "/tmp/$CUDA_KEYRING"
    apt_update

    if $NEED_OPEN_MODULE_FIX; then
        info "Switching from proprietary to OPEN kernel modules for GH200..."
        # Remove proprietary kernel modules if present
        apt-get remove -y --purge nvidia-kernel-source-550 2>/dev/null || true
        # Install open kernel modules — required for GH200 self-hosted GPU
        apt-get install -y --no-install-recommends \
            nvidia-kernel-open-550 \
            cuda-toolkit-12-4
        # Rebuild initramfs so the open module loads on next boot
        update-initramfs -u
        success "Open kernel modules installed — REBOOT REQUIRED"
    elif $NEED_INSTALL; then
        info "Installing CUDA 12.4 toolkit and open driver 550 for GH200..."
        apt-get install -y --no-install-recommends \
            cuda-toolkit-12-4 \
            nvidia-kernel-open-550 \
            nvidia-driver-550-open
        # Rebuild initramfs
        update-initramfs -u
    fi

    # Set up PATH and LD_LIBRARY_PATH
    if ! grep -q '/usr/local/cuda' /etc/profile.d/cuda.sh 2>/dev/null; then
        cat > /etc/profile.d/cuda.sh << 'ENVEOF'
export PATH=/usr/local/cuda-12.4/bin${PATH:+:$PATH}
export LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
ENVEOF
        chmod 644 /etc/profile.d/cuda.sh
    fi
    export PATH=/usr/local/cuda-12.4/bin${PATH:+:$PATH}
    export LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

    success "CUDA 12.4 installed"
}

# ─────────────────────────────────────────────────────────────────────────────
#  2. DOCKER CE
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    if command -v docker &>/dev/null; then
        local DOCKER_VER
        DOCKER_VER="$(docker --version)"
        success "Docker already installed: $DOCKER_VER"
        if docker compose version &>/dev/null; then
            success "Docker Compose plugin available"
            return 0
        else
            warn "Docker Compose plugin missing — installing..."
        fi
    else
        info "Docker not found — installing Docker CE..."
    fi

    # Add Docker official GPG key and repo
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" \
        > /etc/apt/sources-list.d/docker.list 2>/dev/null || \
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        ${DISTRO_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt_update
    apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker
    success "Docker CE installed and running"

    # Add current sudo user to docker group if applicable
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

    # Add NVIDIA container toolkit repo
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg --yes

    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt_update
    apt-get install -y --no-install-recommends nvidia-container-toolkit

    # Configure Docker runtime
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
        if docker run --rm --gpus all nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi; then
            success "Docker GPU passthrough works"
        else
            warn "Docker GPU passthrough failed. Try rebooting, then run:"
            warn "  docker run --rm --gpus all nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi"
        fi
    else
        echo ""
        # Check if we just installed open modules (reboot pending)
        if dpkg -l nvidia-kernel-open-550 2>/dev/null | grep -q '^ii'; then
            warn "nvidia-smi failed — this is expected before reboot."
            warn "Open kernel modules are installed. Reboot to activate them:"
            warn "  sudo reboot"
            warn ""
            warn "After reboot, verify with:"
            warn "  nvidia-smi"
            warn "  docker run --rm --gpus all nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi"
        else
            die "nvidia-smi failed — driver installation may have failed"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  GH200 Grace Hopper — CUDA + Docker Setup"
echo "  Target: NVIDIA driver 550+, CUDA 12.4, Docker CE,"
echo "          nvidia-container-toolkit"
echo "══════════════════════════════════════════════════════════════"
echo ""

install_cuda
install_docker
install_nvidia_container_toolkit
verify

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  GH200 host setup complete!"
echo ""
echo "  Next steps:"
echo "    cd $(pwd)"
echo "    bash scripts/install.sh --gpu"
echo ""
echo "  Then start with GH200 overrides:"
echo "    docker compose -f docker-compose.yml \\"
echo "      -f docker-compose.gh200.yml up -d --build"
echo ""
echo "  If nvidia-smi failed above, reboot first:"
echo "    sudo reboot"
echo "══════════════════════════════════════════════════════════════"
echo ""
