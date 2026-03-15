# ─────────────────────────────────────────────────────────────────────────────
# AI Stack — Makefile
#
# Single entry point for all operations.
# Run `make help` to see available targets.
# ─────────────────────────────────────────────────────────────────────────────

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Load config
-include config.env
export

# ── Compose file detection ──────────────────────────────────────────────────
COMPOSE := docker compose -f docker-compose.yml
ifdef GPU
  COMPOSE += -f docker-compose.gpu.yml
endif
ifdef GH200
  COMPOSE += -f docker-compose.gh200.yml
endif
ifdef DEV
  COMPOSE += -f docker-compose.dev.yml
endif
ifdef AUTH
  COMPOSE += -f docker-compose.auth.yml
endif
ifdef SSL
  COMPOSE += -f docker-compose.ssl.yml
endif
ifdef VLLM
  COMPOSE += -f docker-compose.vllm.yml
endif

# ─────────────────────────────────────────────────────────────────────────────
#  Core targets
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: help install up down restart logs status ps

help: ## Show this help
	@echo ""
	@echo "AI Stack — Available Commands"
	@echo "══════════════════════════════════════════════════════════════"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Modifiers (prepend to any target):"
	@echo "  GPU=1    Enable NVIDIA GPU support"
	@echo "  GH200=1  Enable GH200 Grace Hopper support"
	@echo "  DEV=1    Enable dev tools (VS Code, Gitea, Jupyter, Sandbox)"
	@echo "  AUTH=1   Enable Authelia MFA"
	@echo "  SSL=1    Enable HTTPS/SSL"
	@echo "  VLLM=1   Enable vLLM sidecar"
	@echo ""
	@echo "Examples:"
	@echo "  make up                         # Start (CPU mode)"
	@echo "  make up GPU=1                   # Start with GPU"
	@echo "  make up GH200=1 DEV=1           # GH200 + full dev env"
	@echo "  make up GH200=1 DEV=1 AUTH=1    # GH200 + dev + MFA"
	@echo "  make dev                        # Full dev setup (auto-detect GPU)"
	@echo "  make dev-up                     # Start dev stack"
	@echo "  make sandbox-test               # Test sandbox is working"
	@echo "  make setup-bare ONLY=cuda,vllm  # Selective bare-metal"
	@echo "  make mfa-setup                  # Interactive MFA setup"
	@echo "  make download PACK=flux-schnell # Download models"
	@echo ""

install: ## First-time install (generates .env, builds, starts)
	@bash scripts/install.sh $(if $(GPU),--gpu)

up: ## Start all services
	$(COMPOSE) up -d --build

down: ## Stop all services
	$(COMPOSE) down

restart: ## Restart all services
	$(COMPOSE) restart

logs: ## Follow service logs (use SVC=name to filter)
ifdef SVC
	$(COMPOSE) logs -f $(SVC)
else
	$(COMPOSE) logs -f
endif

status: ## Show running containers and health
	$(COMPOSE) ps

ps: status ## Alias for status

# ─────────────────────────────────────────────────────────────────────────────
#  Development & Coding
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: dev dev-up dev-down dev-logs sandbox-test sandbox-shell

dev: ## Full dev setup (VS Code, Gitea, Jupyter, Sandbox + auto-detect GPU)
	bash scripts/setup-dev.sh

dev-up: ## Start dev stack (shortcut for DEV=1 make up)
	docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build

dev-down: ## Stop dev stack
	docker compose -f docker-compose.yml -f docker-compose.dev.yml down

dev-logs: ## Follow dev service logs
ifdef SVC
	docker compose -f docker-compose.yml -f docker-compose.dev.yml logs -f $(SVC)
else
	docker compose -f docker-compose.yml -f docker-compose.dev.yml logs -f
endif

sandbox-test: ## Verify sandbox is working (runs hello world in 5 languages)
	@echo "Testing Python..."
	@curl -sf http://localhost/sandbox/execute -H 'Content-Type: application/json' \
		-d '{"code":"print(\"Hello from Python!\")","language":"python"}' | jq -r '.stdout' || echo "FAILED"
	@echo "Testing JavaScript..."
	@curl -sf http://localhost/sandbox/execute -H 'Content-Type: application/json' \
		-d '{"code":"console.log(\"Hello from JavaScript!\")","language":"javascript"}' | jq -r '.stdout' || echo "FAILED"
	@echo "Testing Go..."
	@curl -sf http://localhost/sandbox/execute -H 'Content-Type: application/json' \
		-d '{"code":"package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"Hello from Go!\")}","language":"go"}' | jq -r '.stdout' || echo "FAILED"
	@echo "Testing Bash..."
	@curl -sf http://localhost/sandbox/execute -H 'Content-Type: application/json' \
		-d '{"code":"echo Hello from Bash!","language":"bash"}' | jq -r '.stdout' || echo "FAILED"
	@echo "Testing Rust..."
	@curl -sf http://localhost/sandbox/execute -H 'Content-Type: application/json' \
		-d '{"code":"fn main(){println!(\"Hello from Rust!\");}","language":"rust"}' | jq -r '.stdout' || echo "FAILED"
	@echo "All sandbox tests complete!"

sandbox-shell: ## Open a shell in the sandbox container
	docker exec -it ai-sandbox bash

# ─────────────────────────────────────────────────────────────────────────────
#  GH200 / Bare-Metal
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: setup-cuda setup-bare setup-full

setup-cuda: ## Install CUDA + Docker on GH200 host
	sudo bash scripts/install-cuda-gh200.sh

setup-bare: ## Bare-metal setup (no Docker) — use ONLY=cuda,vllm for selective
ifdef ONLY
	sudo bash scripts/setup-gh200-bare.sh --only $(ONLY)
else
	sudo bash scripts/setup-gh200-bare.sh
endif

setup-full: ## Full GH200 stack (CUDA + Docker + all services)
	sudo bash scripts/setup-gh200-full.sh

# ─────────────────────────────────────────────────────────────────────────────
#  MFA / Security
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: mfa-setup mfa-enable mfa-disable mfa-status mfa-add-user

mfa-setup: ## Interactive MFA setup (YubiKey + TOTP)
	bash scripts/setup-mfa.sh

mfa-enable: ## Enable MFA authentication
	bash scripts/setup-mfa.sh enable

mfa-disable: ## Disable MFA, revert to basic auth
	bash scripts/setup-mfa.sh disable

mfa-status: ## Show MFA status and users
	bash scripts/setup-mfa.sh status

mfa-add-user: ## Add MFA user: make mfa-add-user USER=name EMAIL=x@y.z
	bash scripts/setup-mfa.sh add-user $(USER) $(EMAIL)

# ─────────────────────────────────────────────────────────────────────────────
#  SSL
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: ssl-setup

ssl-setup: ## Setup Let's Encrypt SSL: make ssl-setup DOMAIN=x.com EMAIL=y@z
	bash scripts/setup-ssl.sh $(DOMAIN) $(EMAIL)

# ─────────────────────────────────────────────────────────────────────────────
#  Models
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: download download-sd15 download-sdxl download-flux download-upscalers

download: ## Download model pack: make download PACK=sd15
	bash scripts/download-models.sh $(PACK)

download-sd15: ## Download Stable Diffusion 1.5
	bash scripts/download-models.sh sd15

download-sdxl: ## Download SDXL 1.0
	bash scripts/download-models.sh sdxl

download-flux: ## Download FLUX.1-schnell
	bash scripts/download-models.sh flux-schnell

download-upscalers: ## Download upscale models
	bash scripts/download-models.sh upscalers

# ─────────────────────────────────────────────────────────────────────────────
#  Ollama model management
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: ollama-pull ollama-code

ollama-pull: ## Pull an Ollama model: make ollama-pull MODEL=llama3.2
	docker exec ai-ollama ollama pull $(MODEL)

ollama-code: ## Pull coding-focused Ollama models
	docker exec ai-ollama ollama pull codellama
	docker exec ai-ollama ollama pull deepseek-coder-v2
	docker exec ai-ollama ollama pull qwen2.5-coder
	docker exec ai-ollama ollama pull starcoder2

# ─────────────────────────────────────────────────────────────────────────────
#  Update / Maintenance
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: update pull clean

update: ## Update all services to latest
	bash scripts/update.sh $(if $(GPU),--gpu) $(if $(GH200),--gh200)

pull: ## Pull latest images without restarting
	$(COMPOSE) pull --ignore-pull-failures

clean: ## Remove stopped containers, dangling images, build cache
	docker system prune -f
	docker volume prune -f
