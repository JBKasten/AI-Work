#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — ComfyUI model downloader
# Usage: bash scripts/download-models.sh [pack]
#
# Packs:
#   sd15       Stable Diffusion 1.5 (1.9 GB)
#   sdxl       SDXL 1.0 base + refiner (12 GB)
#   flux-dev   FLUX.1-dev (24 GB, requires HF_TOKEN with accepted license)
#   flux-schnell FLUX.1-schnell (24 GB)
#   upscalers  ESRGAN / RealESRGAN upscale models (400 MB)
#   all        Everything above (large download)
#
# Examples:
#   bash scripts/download-models.sh sd15
#   HF_TOKEN=hf_xxx bash scripts/download-models.sh flux-dev
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PACK="${1:-sd15}"
HF_TOKEN="${HF_TOKEN:-}"

COMFYUI_CONTAINER="ai-comfyui"

info()    { echo "[Models] $*"; }
success() { echo "[Models] ✓ $*"; }
die()     { echo "[Models] ERROR: $*" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
container_running() {
    docker inspect -f '{{.State.Running}}' "$COMFYUI_CONTAINER" 2>/dev/null | grep -q true
}

hf_download() {
    local repo="$1" filename="$2" dest_dir="$3"
    local url="https://huggingface.co/${repo}/resolve/main/${filename}"
    local auth_header=""
    [[ -n "$HF_TOKEN" ]] && auth_header="Authorization: Bearer ${HF_TOKEN}"

    info "Downloading ${filename} from ${repo}..."
    if container_running; then
        docker exec "$COMFYUI_CONTAINER" bash -c "
            mkdir -p /app/${dest_dir} &&
            wget -q --show-progress \
                ${auth_header:+--header='${auth_header}'} \
                -O /app/${dest_dir}/$(basename ${filename}) \
                '${url}'
        "
    else
        die "ComfyUI container is not running. Start the stack first: docker compose up -d"
    fi
    success "$(basename "${filename}") saved to ${dest_dir}/"
}

civitai_download() {
    local url="$1" filename="$2" dest_dir="$3"
    info "Downloading ${filename} from CivitAI..."
    if container_running; then
        docker exec "$COMFYUI_CONTAINER" bash -c "
            mkdir -p /app/${dest_dir} &&
            wget -q --show-progress \
                --content-disposition \
                -O /app/${dest_dir}/${filename} \
                '${url}'
        "
    else
        die "ComfyUI container is not running. Start the stack first: docker compose up -d"
    fi
    success "${filename} saved to ${dest_dir}/"
}

# ── Model packs ───────────────────────────────────────────────────────────────
pack_sd15() {
    info "=== Stable Diffusion 1.5 pack ==="
    hf_download \
        "runwayml/stable-diffusion-v1-5" \
        "v1-5-pruned-emaonly.safetensors" \
        "models/checkpoints"

    # VAE
    hf_download \
        "stabilityai/sd-vae-ft-mse-original" \
        "vae-ft-mse-840000-ema-pruned.safetensors" \
        "models/vae"

    # Embeddings (negative)
    hf_download \
        "embed/EasyNegative" \
        "EasyNegative.safetensors" \
        "models/embeddings" 2>/dev/null || \
    info "EasyNegative embedding skipped (CivitAI — download manually if needed)"
}

pack_sdxl() {
    info "=== SDXL 1.0 pack ==="
    hf_download \
        "stabilityai/stable-diffusion-xl-base-1.0" \
        "sd_xl_base_1.0.safetensors" \
        "models/checkpoints"

    hf_download \
        "stabilityai/stable-diffusion-xl-refiner-1.0" \
        "sd_xl_refiner_1.0.safetensors" \
        "models/checkpoints"

    hf_download \
        "madebyollin/sdxl-vae-fp16-fix" \
        "sdxl_vae.safetensors" \
        "models/vae"
}

pack_flux_dev() {
    [[ -z "$HF_TOKEN" ]] && die "FLUX.1-dev requires a HuggingFace token with accepted license.\nSet HF_TOKEN=hf_xxx and re-run."
    info "=== FLUX.1-dev pack (requires HF token) ==="
    hf_download \
        "black-forest-labs/FLUX.1-dev" \
        "flux1-dev.safetensors" \
        "models/checkpoints"

    # FLUX text encoders
    hf_download \
        "comfyanonymous/flux_text_encoders" \
        "clip_l.safetensors" \
        "models/clip"
    hf_download \
        "comfyanonymous/flux_text_encoders" \
        "t5xxl_fp16.safetensors" \
        "models/clip"

    # FLUX VAE
    hf_download \
        "black-forest-labs/FLUX.1-dev" \
        "ae.safetensors" \
        "models/vae"
}

pack_flux_schnell() {
    info "=== FLUX.1-schnell pack ==="
    hf_download \
        "black-forest-labs/FLUX.1-schnell" \
        "flux1-schnell.safetensors" \
        "models/checkpoints"

    hf_download \
        "comfyanonymous/flux_text_encoders" \
        "clip_l.safetensors" \
        "models/clip"
    hf_download \
        "comfyanonymous/flux_text_encoders" \
        "t5xxl_fp16.safetensors" \
        "models/clip"

    hf_download \
        "black-forest-labs/FLUX.1-schnell" \
        "ae.safetensors" \
        "models/vae"
}

pack_upscalers() {
    info "=== Upscale models pack ==="
    hf_download \
        "ai-forever/Real-ESRGAN" \
        "RealESRGAN_x4.pth" \
        "models/upscale_models"

    hf_download \
        "Phips/4xNomos8kSCHAT-L_span_pretrain" \
        "4xNomos8kSCHAT-L_span_pretrain.pth" \
        "models/upscale_models" 2>/dev/null || \
    info "Nomos upscaler skipped"
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "$PACK" in
    sd15)          pack_sd15 ;;
    sdxl)          pack_sdxl ;;
    flux-dev)      pack_flux_dev ;;
    flux-schnell)  pack_flux_schnell ;;
    upscalers)     pack_upscalers ;;
    all)
        pack_sd15
        pack_sdxl
        pack_upscalers
        [[ -n "$HF_TOKEN" ]] && pack_flux_dev || info "Skipping FLUX.1-dev (no HF_TOKEN set)"
        ;;
    *)
        echo "Unknown pack: ${PACK}"
        echo "Available packs: sd15 sdxl flux-dev flux-schnell upscalers all"
        exit 1
        ;;
esac

echo ""
echo "Done! Models are available in ComfyUI immediately."
echo "Open http://localhost/comfyui and load a workflow to use them."
