#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — Development Environment Setup
#
# Sets up the full coding stack:
#   - code-server (VS Code in browser) with extensions
#   - Gitea (self-hosted Git with code review + CI)
#   - Jupyter (interactive notebooks)
#   - Code sandbox (safe multi-language execution)
#   - Open WebUI tools (code_execute, run_tests, lint, analyze, review)
#
# Usage:
#   bash scripts/setup-dev.sh            # full dev setup
#   bash scripts/setup-dev.sh --no-gpu   # CPU only
#
# After setup:
#   VS Code   → http://localhost/code/
#   Gitea     → http://localhost/git/
#   Jupyter   → http://localhost/jupyter/
#   Open WebUI→ http://localhost/  (with coding tools pre-loaded)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOG_PREFIX="Dev-Setup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

NO_GPU=false
WITH_AUTH=false
for arg in "$@"; do
    case $arg in
        --no-gpu)   NO_GPU=true ;;
        --with-auth) WITH_AUTH=true ;;
    esac
done

banner \
    "AI Stack — Development Environment Setup" \
    "" \
    "Components:" \
    "  - code-server (VS Code in browser)" \
    "  - Gitea (self-hosted Git + CI)" \
    "  - Jupyter (interactive notebooks)" \
    "  - Code Sandbox (multi-language execution)" \
    "  - Open WebUI coding tools"

# ── 1. Generate dev secrets in .env ──────────────────────────────────────────
info "Configuring .env for dev environment..."

cd "$ROOT_DIR"
[[ -f .env ]] || cp .env.example .env

# Code-server password
if ! grep -q "^CODE_SERVER_PASSWORD=" .env 2>/dev/null; then
    local_pass="$(openssl rand -base64 12 2>/dev/null || echo 'changeme')"
    echo "CODE_SERVER_PASSWORD=${local_pass}" >> .env
    info "code-server password: ${local_pass}"
fi

# Jupyter token
if ! grep -q "^JUPYTER_TOKEN=" .env 2>/dev/null; then
    local_token="$(openssl rand -hex 16 2>/dev/null || echo 'ai-stack')"
    echo "JUPYTER_TOKEN=${local_token}" >> .env
    info "Jupyter token: ${local_token}"
fi

success ".env configured"

# ── 2. Build compose command ─────────────────────────────────────────────────
COMPOSE="docker compose -f docker-compose.yml"

# Auto-detect GPU
if ! $NO_GPU && has_cmd nvidia-smi && nvidia-smi &>/dev/null; then
    detect_arch
    if [[ "$ARCH" == "aarch64" ]]; then
        COMPOSE+=" -f docker-compose.gh200.yml"
        info "GH200 GPU detected"
    else
        COMPOSE+=" -f docker-compose.gpu.yml"
        info "NVIDIA GPU detected"
    fi
else
    info "Running in CPU mode"
fi

COMPOSE+=" -f docker-compose.dev.yml"

if $WITH_AUTH; then
    COMPOSE+=" -f docker-compose.auth.yml"
    info "MFA auth enabled"
fi

# ── 3. Build sandbox container ───────────────────────────────────────────────
info "Building code sandbox (multi-language: Python, JS/TS, Go, Rust, Bash)..."
info "This includes compilers, test frameworks, and linters — may take a few minutes..."
$COMPOSE build sandbox

# ── 4. Start everything ─────────────────────────────────────────────────────
info "Starting all services..."
$COMPOSE up -d

# ── 5. Wait for services ────────────────────────────────────────────────────
info "Waiting for services to come up..."

wait_for_service() {
    local name="$1" url="$2" max="${3:-30}"
    for i in $(seq 1 "$max"); do
        if curl -sf "$url" >/dev/null 2>&1; then
            success "$name is ready"
            return 0
        fi
        sleep 3
    done
    warn "$name did not respond within $((max * 3))s"
}

wait_for_service "Open WebUI"  "http://localhost:80/health"
wait_for_service "Code Sandbox" "http://localhost:80/sandbox/health"
wait_for_service "code-server" "http://localhost:80/code/"  20
wait_for_service "Gitea"       "http://localhost:80/git/"   20
wait_for_service "Jupyter"     "http://localhost:80/jupyter/" 20

# ── 6. Install code-server extensions ───────────────────────────────────────
info "Installing VS Code extensions..."
docker exec ai-code-server sh -c '
    code-server --install-extension ms-python.python 2>/dev/null || true
    code-server --install-extension ms-python.black-formatter 2>/dev/null || true
    code-server --install-extension esbenp.prettier-vscode 2>/dev/null || true
    code-server --install-extension dbaeumer.vscode-eslint 2>/dev/null || true
    code-server --install-extension bradlc.vscode-tailwindcss 2>/dev/null || true
    code-server --install-extension eamodio.gitlens 2>/dev/null || true
    code-server --install-extension usernamehw.errorlens 2>/dev/null || true
    code-server --install-extension streetsidesoftware.code-spell-checker 2>/dev/null || true
    code-server --install-extension redhat.vscode-yaml 2>/dev/null || true
    code-server --install-extension golang.Go 2>/dev/null || true
    code-server --install-extension rust-lang.rust-analyzer 2>/dev/null || true
' 2>/dev/null || warn "Some extensions may not have installed — you can add them later"
success "VS Code extensions installed"

# ── 7. Print tool import instructions ───────────────────────────────────────
info "Copying Open WebUI tools..."

IP="$(get_public_ip)"
CODE_PASS="$(grep '^CODE_SERVER_PASSWORD=' .env | cut -d= -f2)"
JUPYTER_TOK="$(grep '^JUPYTER_TOKEN=' .env | cut -d= -f2)"

banner \
    "Dev Environment is READY!" \
    "" \
    "Services:" \
    "  Open WebUI   →  http://${IP}/" \
    "  VS Code      →  http://${IP}/code/    (password: ${CODE_PASS})" \
    "  Gitea        →  http://${IP}/git/     (register on first visit)" \
    "  Jupyter      →  http://${IP}/jupyter/ (token: ${JUPYTER_TOK})" \
    "  ComfyUI      →  http://${IP}/comfyui/" \
    "  Sandbox API  →  http://${IP}/sandbox/languages" \
    "" \
    "Open WebUI Coding Tools:" \
    "  Import these tools in Open WebUI → Workspace → Tools:" \
    "    open-webui/tools/code_execute.py   — Execute code (6 languages)" \
    "    open-webui/tools/run_tests.py      — Run test suites" \
    "    open-webui/tools/lint_code.py      — Lint & auto-fix" \
    "    open-webui/tools/analyze_code.py   — Security + complexity analysis" \
    "    open-webui/tools/code_review.py    — Full automated code review" \
    "    open-webui/tools/git_operations.py — Git clone + Gitea integration" \
    "" \
    "LiteLLM Coding Models:" \
    "  code         — Best available (Claude → GPT-4o → Gemini)" \
    "  code-fast    — Quick tasks (Haiku → Groq → GPT-4o-mini)" \
    "  code-heavy   — Architecture/debugging (Opus → GPT-4o)" \
    "  code-review  — Specialised review (Sonnet → GPT-4o)" \
    "  codestral    — Mistral's code model" \
    "  deepseek-coder — DeepSeek coding specialist" \
    "" \
    "Sandbox supports: Python, JavaScript, TypeScript, Go, Rust, Bash" \
    "" \
    "To restart:" \
    "  ${COMPOSE} up -d" \
    "" \
    "Logs:" \
    "  ${COMPOSE} logs -f"
