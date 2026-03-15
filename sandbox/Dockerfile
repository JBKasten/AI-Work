FROM python:3.12-slim

# ─────────────────────────────────────────────────────────────────────────────
# Code Sandbox — Safe execution environment for LLM-generated code
#
# Multi-language runtime with testing frameworks, linters, and security tools.
# Runs as unprivileged user 'sandbox' with resource limits.
# ─────────────────────────────────────────────────────────────────────────────

ENV DEBIAN_FRONTEND=noninteractive

# System packages: compilers, runtimes, tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build tools
    build-essential gcc g++ make cmake \
    # Node.js 20 (via NodeSource)
    curl ca-certificates gnupg \
    # System utilities
    git jq tree file procps \
    # Shell tools
    shellcheck \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Go
RUN curl -fsSL https://go.dev/dl/go1.22.5.linux-$(dpkg --print-architecture).tar.gz \
    | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"

# Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# ── Python packages (testing + linting + AI/ML essentials) ──────────────────
RUN pip install --no-cache-dir \
    # Testing
    pytest pytest-cov pytest-asyncio pytest-timeout pytest-xdist \
    hypothesis \
    # Linting & formatting
    ruff mypy black isort bandit \
    # Type stubs
    types-requests types-PyYAML \
    # Code analysis
    pylint radon vulture \
    # Web / API
    fastapi uvicorn requests httpx aiohttp \
    # Data
    numpy pandas polars \
    # Utilities
    pydantic pyyaml toml rich click typer \
    # Coverage
    coverage \
    # Security
    safety pip-audit

# ── Node packages (global) ──────────────────────────────────────────────────
RUN npm install -g \
    typescript ts-node \
    jest @types/jest ts-jest \
    eslint prettier \
    vitest \
    esbuild

# ── Sandbox user (unprivileged) ─────────────────────────────────────────────
RUN useradd -m -s /bin/bash sandbox
WORKDIR /home/sandbox/workspace

# ── API server for code execution ───────────────────────────────────────────
COPY server.py /opt/sandbox/server.py
RUN chown -R sandbox:sandbox /home/sandbox

EXPOSE 8080
USER sandbox

CMD ["python", "/opt/sandbox/server.py"]
