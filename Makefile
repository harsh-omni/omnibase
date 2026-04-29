.PHONY: install setup dev test docker-up docker-down seed-keycloak update status clean help

REPOS_DIR := $(CURDIR)/repos
SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install: ## Clone all repos, build Python envs, install Node deps
	@echo "==> Installing ONEX platform..."
	@bash install.sh
	@echo "==> Installation complete. Run 'make setup' to configure environment, start infra, and seed Keycloak."

setup: ## Create .env from template, start Docker infrastructure, seed Keycloak
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "==> Created .env from template. Edit it with your configuration."; \
	else \
		echo "==> .env already exists, skipping."; \
	fi
	@$(MAKE) docker-up
	@$(MAKE) seed-keycloak

dev: ## Start omnidash dev server and show onex CLI help
	@echo "==> Starting development environment..."
	@if [ -d $(REPOS_DIR)/omnidash ]; then \
		echo "Starting omnidash dev server on port 3000..."; \
		cd $(REPOS_DIR)/omnidash && PORT=3000 npm run dev & \
	fi
	@if [ -d $(REPOS_DIR)/omnibase_core ]; then \
		echo ""; \
		echo "==> onex CLI:"; \
		cd $(REPOS_DIR)/omnibase_core && uv run onex --help 2>/dev/null || echo "(onex CLI not available — run 'make install' first)"; \
	fi

test: ## Run tests across all Python repos
	@echo "==> Running tests..."
	@for repo in omnibase_core omnibase_infra omnibase_spi omnibase_compat omniclaude omniintelligence omnimemory onex_change_control; do \
		if [ -d $(REPOS_DIR)/$$repo ]; then \
			echo ""; \
			echo "--- Testing $$repo ---"; \
			cd $(REPOS_DIR)/$$repo && uv run pytest tests/ -x -q 2>&1 | tail -5 || true; \
		fi; \
	done
	@echo ""
	@echo "==> Tests complete."

docker-up: ## Start Docker infrastructure (Postgres, Redpanda, Valkey, Keycloak)
	@echo "==> Starting Docker infrastructure..."
	@if [ -d $(REPOS_DIR)/omnibase_infra/docker ]; then \
		cd $(REPOS_DIR)/omnibase_infra && docker compose -f docker/docker-compose.infra.yml --profile auth up -d; \
	else \
		echo "ERROR: omnibase_infra not found. Run 'make install' first."; \
		exit 1; \
	fi

docker-down: ## Stop Docker infrastructure
	@echo "==> Stopping Docker infrastructure..."
	@if [ -d $(REPOS_DIR)/omnibase_infra/docker ]; then \
		cd $(REPOS_DIR)/omnibase_infra && docker compose -f docker/docker-compose.infra.yml --profile auth down; \
	fi

KC_URL ?= http://localhost:28080
OMNIBASE_ENV_FILE ?= $(HOME)/.omnibase/.env

seed-keycloak: ## Reconcile Keycloak clients from desired-clients.json (idempotent)
	@if [ ! -f "$(OMNIBASE_ENV_FILE)" ]; then \
		echo "ERROR: $(OMNIBASE_ENV_FILE) not found. Create it with KEYCLOAK_ADMIN_USERNAME and KEYCLOAK_ADMIN_PASSWORD set, or override OMNIBASE_ENV_FILE."; \
		exit 1; \
	fi
	@echo "==> Waiting for Keycloak at $(KC_URL) to become ready (max 90s)..."
	@i=0; until curl -fsS -m 3 $(KC_URL)/realms/omninode/.well-known/openid-configuration > /dev/null 2>&1; do \
		i=$$((i+1)); \
		if [ $$i -gt 30 ]; then \
			echo "ERROR: Keycloak at $(KC_URL) did not become ready within 90s."; \
			echo "--- docker ps (keycloak) ---"; \
			docker ps -a --filter name=omnibase-infra-keycloak --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true; \
			echo "--- last 40 lines of keycloak logs ---"; \
			docker logs --tail 40 omnibase-infra-keycloak 2>&1 || true; \
			exit 1; \
		fi; \
		echo "   Keycloak not ready — retrying in 3s... ($$i/30)"; \
		sleep 3; \
	done
	@echo "==> Keycloak ready. Running client reconciler..."
	@# --reset-bootstrap-admin invokes 'kc.sh bootstrap-admin user' inside the local Keycloak
	@# container so the master-realm admin password matches KEYCLOAK_ADMIN_PASSWORD.
	@# Caller-side gating: only passed when KC_URL host is localhost/127.0.0.1; the callee
	@# (seed-keycloak-clients.py) has its own localhost guard for defense-in-depth.
	@set -a && . "$(OMNIBASE_ENV_FILE)" && set +a && \
		case "$(KC_URL)" in \
			http://localhost:*|http://127.0.0.1:*) RESET_FLAG=--reset-bootstrap-admin ;; \
			*) RESET_FLAG="" ;; \
		esac && \
		cd $(REPOS_DIR)/omnibase_infra && uv run python scripts/seed-keycloak-clients.py \
			--kc-url $(KC_URL) --realm omninode \
			--admin-username "$${KEYCLOAK_ADMIN_USERNAME:?KEYCLOAK_ADMIN_USERNAME must be set in $(OMNIBASE_ENV_FILE)}" \
			--admin-password "$${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set in $(OMNIBASE_ENV_FILE)}" \
			$$RESET_FLAG \
			--config $(REPOS_DIR)/omnibase_infra/docker/keycloak/desired-clients.json

update: ## Pull latest main across all repos
	@echo "==> Updating all repositories..."
	@for dir in $(REPOS_DIR)/*/; do \
		repo=$$(basename $$dir); \
		echo "--- $$repo ---"; \
		cd $$dir && git pull --ff-only 2>&1 | tail -1 || true; \
	done
	@echo ""
	@echo "==> Update complete."

status: ## Show repo versions and infrastructure health
	@echo "==> Repository status:"
	@for dir in $(REPOS_DIR)/*/; do \
		repo=$$(basename $$dir); \
		branch=$$(cd $$dir && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?"); \
		commit=$$(cd $$dir && git log -1 --format='%h %s' 2>/dev/null || echo "?"); \
		printf "  %-25s %-10s %s\n" "$$repo" "[$$branch]" "$$commit"; \
	done
	@echo ""
	@echo "==> Infrastructure status:"
	@docker ps --filter "name=omnibase-infra" --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || echo "  (Docker not running or no infrastructure containers found)"

clean: ## Remove all cloned repos (destructive!)
	@echo "WARNING: This will delete all cloned repositories in repos/."
	@read -p "Are you sure? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -rf $(REPOS_DIR); \
		echo "==> Cleaned."; \
	else \
		echo "==> Cancelled."; \
	fi
