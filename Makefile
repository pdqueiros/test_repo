SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
MAKEFLAGS += --no-print-directory

DOCKER_COMPOSE_BUILD_FILE ?= docker-compose-build.yaml
UV_GCP_AUTH_ENV_FILE ?= .uv-gcp-auth.env
UV_GCP_TOKEN_CACHE_FILE ?= .gcp-token-cache.env
TOKEN_TTL_SECONDS ?= 3000


.PHONY: install activate activate_prod activate_hetzner update test format check_uv audit_docs test_connections docker_up docker_down docker_reset help auth-gcp build install-private auth-clean

DOCS_DIR := tmp/audits/gx/uncommitted/data_docs/local_site
DOCS_PORT := 8080
DEV_ENV_FILE := config/env_files/dev.env
COMPOSE_FILES := -f docker-compose-es.yaml -f docker-compose-minio.yaml -f docker-compose-postgres.yaml -f docker-compose-rabbitmq.yaml

# This block defines the "dictionary" logic once.
# We use $$ everywhere so Make passes the dollar signs to the Bash shell.
define SETUP_ENV_VARS
	declare -A ENV
	ENV["PACKAGE"]=$$(grep -m 1 'name' pyproject.toml | sed -E 's/name = "(.*)"/\1/')
	ENV["PYTHON_VERSION"]=$$(grep -m 1 'python' pyproject.toml | sed -nE 's/.*[~^]=?([0-9]+\.[0-9]+).*/\1/p')
	ENV["ENV_DIR"]="${HOME}/envs/$${ENV["PACKAGE"]}"
	ENV["ENV_PATH"]="$${ENV["ENV_DIR"]}/bin/activate"
	source "$(UV_GCP_AUTH_ENV_FILE)"
endef

help:
	@printf '%s\n' \
	  'Consumer private-index helpers' \
	  '' \
	  'Targets:' \
	  '  auth-gcp        Create or refresh Artifact Registry auth env file' \
	  '  build-local     Build with docker compose using auth from auth-gcp' \
	  '  install-private Run uv sync with private-index auth from auth-gcp' \
	  '  auth-clean      Remove generated auth/token cache files' \
	  '' \
	  'Behavior:' \
	  '  - Default: short-lived token via gcloud (cached for TOKEN_TTL_SECONDS)' \
	  '  - Fallback (no gcloud): UV_INDEX_GCP_LONG_USERNAME + UV_INDEX_GCP_LONG_PASSWORD'



# --- 0. Requirement Check ---
check_uv:
	@command -v uv >/dev/null 2>&1 || { \
		echo >&2 "Error: 'uv' is not installed."; \
		echo >&2 "Please install it via: wget -qO- https://astral.sh/uv/install.sh | sh"; \
		exit 1; \
	}

# --- 1. Install ---
install:
	@$(SETUP_ENV_VARS)
	if [ ! -d "$${ENV["ENV_DIR"]}" ]; then
		echo "Installing environment for $${ENV["PACKAGE"]}..."
		uv venv "$${ENV["ENV_DIR"]}" --python "$${ENV["PYTHON_VERSION"]}"
		source "$${ENV["ENV_PATH"]}" && uv sync --active --all-extras && commitizen_versioning move_hooks
		echo "Install complete. Use 'make activate' to activate it"
	else
		echo "Environment for $${ENV["PACKAGE"]} already exists at $${ENV["ENV_DIR"]}. Use 'make activate' to activate it, or 'make update' to update it."

	fi
	unset ENV

# --- 2. Activate ---
activate:
	@if [ "$$IN_MAKE_SHELL" = "true" ]; then
		echo "Already inside a sub-shell, either exit the sub-shell with 'exit'/ctrl+d or start a new terminal session."
		exit 0
	fi
	$(SETUP_ENV_VARS)
	if [ ! -f "$${ENV["ENV_PATH"]}" ]; then
		echo "Error: Environment not found. Run 'make install' first."
		exit 1
	fi
	echo "--- Entering $${ENV["PACKAGE"]} environment and sourcing .env (type 'exit' to leave) ---"
	bash --rcfile <(echo "source ~/.bashrc; source scripts/load_dot_env_dev.sh; source $${ENV["ENV_PATH"]}; export IN_MAKE_SHELL=true")
	unset ENV

activate_hetzner:
	@if [ "$$IN_MAKE_SHELL" = "true" ]; then
		echo "Already inside a sub-shell, either exit the sub-shell with 'exit'/ctrl+d or start a new terminal session."
		exit 0
	fi
	$(SETUP_ENV_VARS)
	if [ ! -f "$${ENV["ENV_PATH"]}" ]; then
		echo "Error: Environment not found. Run 'make install' first."
		exit 1
	fi
	echo "--- Entering $${ENV["PACKAGE"]} environment and sourcing .env (type 'exit' to leave) ---"
	bash --rcfile <(echo "source ~/.bashrc; source scripts/load_dot_env_hetzner.sh; source $${ENV["ENV_PATH"]}; export IN_MAKE_SHELL=true")
	unset ENV

# --- 2. Activate ---
activate_prod:
	@if [ "$$IN_MAKE_SHELL" = "true" ]; then
		echo "Already inside a sub-shell, either exit the sub-shell with 'exit'/ctrl+d or start a new terminal session."
		exit 0
	fi
	$(SETUP_ENV_VARS)
	if [ ! -f "$${ENV["ENV_PATH"]}" ]; then
		echo "Error: Environment not found. Run 'make install' first."
		exit 1
	fi
	echo "--- Entering $${ENV["PACKAGE"]} environment and sourcing .env (type 'exit' to leave) ---"
	bash --rcfile <(echo "source ~/.bashrc; source scripts/load_dot_env_prod.sh; source $${ENV["ENV_PATH"]}; export IN_MAKE_SHELL=true")
	unset ENV

# --- 3. Update ---
update:
	@$(SETUP_ENV_VARS)
	if [ ! -f "$${ENV["ENV_PATH"]}" ]; then
		echo "Error: Environment not found. Run 'make install' first."
		exit 1
	fi
	echo "Updating environment for $${ENV["PACKAGE"]}..."
	rm uv.lock
	uv venv  --clear "$${ENV["ENV_DIR"]}" --python "$${ENV["PYTHON_VERSION"]}"
	source "$${ENV["ENV_PATH"]}" && uv sync --active --all-extras
	unset ENV
	echo "Update complete."


test:
	@echo "Running tests via uv..."
	@$(SETUP_ENV_VARS)
	bash --rcfile <(echo "source ~/.bashrc; source scripts/load_dot_env_dev.sh; source $${ENV["ENV_PATH"]}; export IN_MAKE_SHELL=true") \
	-c "uv run --all-extras --group checks pytest -q"
	unset ENV

format:
	@echo "Running ruff formatter/linter via temporary uv environment..."
	uv run --with ruff ruff check . --fix
	uv run --with ruff ruff format .


test_connections:
	@$(SETUP_ENV_VARS)
	source scripts/load_dot_env_prod.sh
	source "$${ENV["ENV_PATH"]}"
	python scripts/test_connections.py

audit_docs:
	@if [ ! -d "$(DOCS_DIR)" ]; then \
		echo "Error: Data Docs directory not found at $(DOCS_DIR)."; \
		echo "Run your audit script first to generate the reports."; \
		exit 1; \
	fi
	@echo "--- Starting Data Docs Server at http://localhost:$(DOCS_PORT) ---"
	@echo "Press Ctrl+C to stop the server."
	@python -m http.server $(DOCS_PORT) --directory $(DOCS_DIR)

docker_up:
	@echo "Starting ES + MinIO + Postgres..."
	if ! docker compose --env-file $(DEV_ENV_FILE) $(COMPOSE_FILES) up -d --remove-orphans; then
		echo "docker compose up failed. Printing setup container logs..." >&2
		docker compose --env-file $(DEV_ENV_FILE) $(COMPOSE_FILES) logs --no-color setup || true
		exit 1
	fi

docker_down:
	@echo "Stopping ES + MinIO + Postgres..."
	docker compose --env-file $(DEV_ENV_FILE) $(COMPOSE_FILES) down --remove-orphans

docker_reset:
	@echo "Resetting ES + MinIO + Postgres containers and named volumes..."
	docker compose --env-file $(DEV_ENV_FILE) $(COMPOSE_FILES) down -v --remove-orphans
	docker compose --env-file $(DEV_ENV_FILE) $(COMPOSE_FILES) up -d --remove-orphans





auth-gcp:
	now="$$(date +%s)"
	token=""

	if command -v gcloud >/dev/null 2>&1; then
	  if [[ -f "$(UV_GCP_TOKEN_CACHE_FILE)" ]]; then
	    source "$(UV_GCP_TOKEN_CACHE_FILE)"
	  fi

	  if [[ -n "$${TOKEN_VALUE:-}" && -n "$${TOKEN_EXPIRES_AT:-}" && "$$now" -lt "$$TOKEN_EXPIRES_AT" ]]; then
	    token="$$TOKEN_VALUE"
	  else
	    token="$$(gcloud auth print-access-token)"
	    expires_at="$$((now + $(TOKEN_TTL_SECONDS)))"
	    printf 'TOKEN_VALUE=%q\nTOKEN_EXPIRES_AT=%q\n' "$$token" "$$expires_at" > "$(UV_GCP_TOKEN_CACHE_FILE)"
	  fi

	  printf 'UV_INDEX_GCP_USERNAME=%q\nUV_INDEX_GCP_PASSWORD=%q\n' "oauth2accesstoken" "$$token" > "$(UV_GCP_AUTH_ENV_FILE)"
	  exit 0
	fi

	: "$${UV_INDEX_GCP_LONG_USERNAME:?set UV_INDEX_GCP_LONG_USERNAME when gcloud is unavailable}"
	: "$${UV_INDEX_GCP_LONG_PASSWORD:?set UV_INDEX_GCP_LONG_PASSWORD when gcloud is unavailable}"
	printf 'UV_INDEX_GCP_USERNAME=%q\nUV_INDEX_GCP_PASSWORD=%q\n' \
	  "$$UV_INDEX_GCP_LONG_USERNAME" "$$UV_INDEX_GCP_LONG_PASSWORD" > "$(UV_GCP_AUTH_ENV_FILE)"

build: auth-gcp
	: "$${REGISTRY:?set REGISTRY (e.g. europe-west1-docker.pkg.dev/<project>/<repo>)}"
	: "$${PACKAGE_NAME:?set PACKAGE_NAME}"
	: "$${IMAGE_TAG:?set IMAGE_TAG}"
	source "$(UV_GCP_AUTH_ENV_FILE)"
	docker compose -f "$(DOCKER_COMPOSE_BUILD_FILE)" build

auth-clean:
	rm -f "$(UV_GCP_AUTH_ENV_FILE)" "$(UV_GCP_TOKEN_CACHE_FILE)"
