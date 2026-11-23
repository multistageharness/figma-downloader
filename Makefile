##
## packages/ts — self-contained Makefile (Node twin)
##
## Node ESM CLI over the workspace SDK (@internal/figma-api-fetch-file, linked
## via a file: dependency into ../../../../figma-api/v100/packages/ts).
## The SDK ships built dist/ + lib/ output, so `make sdk` must run before the
## CLI or its tests — `test`/`audit` depend on it. `make install` regenerates
## node_modules (the registry override lives in .npmrc).
##

FILE_KEY ?= TFTCSGbqpyxex6QRYqqbzb
SDK_DIR := ../../../../figma-api/v100/packages/ts

## Keychain secret store (docs/keychain-env.md): the Figma token comes from the
## environment, else from the macOS keychain through the vendored
## macos-keychain-env. Override the repo, ref and service from the environment.
VENDOR_DIR        := vendor
KEYCHAIN_ENV_DIR  := $(VENDOR_DIR)/macos-keychain-env
KEYCHAIN_ENV_REPO ?= https://github.com/multistageharness/macos-keychain-env
KEYCHAIN_ENV_REF  ?= main
KEYCHAIN_SERVICE  ?= $(or $(FIGMA_KEYCHAIN_SERVICE),figma-api)
KEYCHAIN_KEYS     := FIGMA_TOKEN
KEYCHAIN_CLI      := node $(KEYCHAIN_ENV_DIR)/bin/keychain-env.js

.DEFAULT_GOAL := help

.PHONY: help install sdk typecheck test audit mock run vendor secret secrets clean

help: ## Show this help
	@echo "figma-downloader (Node twin) targets:"
	@echo "  make sdk         build the workspace SDK packages this CLI depends on"
	@echo "  make test        build the SDK, then run the test suite (node --test, no network)"
	@echo "  make typecheck   node --check every source file"
	@echo "  make mock        chunked download of the built-in offline fixture -> stdout"
	@echo "  make run         live download FILE_KEY=<key> (needs FIGMA_TOKEN)"
	@echo "  make install     npm install (links @internal/figma-api-fetch-file)"
	@echo "  make vendor      fetch vendor/macos-keychain-env (keychain secret store)"
	@echo "  make secret KEY=FIGMA_TOKEN  store the token in the macOS keychain (hidden prompt)"
	@echo "  make secrets     list which keychain items exist (reads no values)"
	@echo "  make audit       typecheck + test"
	@echo "  make clean       remove node_modules / out"

install: ## Install/link dependencies (registry override in .npmrc)
	npm install

sdk: ## Build the SDK packages the CLI consumes (dist/ + lib/ must exist)
	npm --prefix $(SDK_DIR) run build --workspace=@internal/figma-api-fetch
	npm --prefix $(SDK_DIR) run build --workspace=@internal/figma-api-fetch-file

typecheck: ## node --check every source file
	npm run typecheck

test: sdk ## Build the SDK, then run the test suite (no network)
	npm test

mock: ## Chunked download of the built-in offline fixture, printed to stdout
	node bin/figma-download.mjs --mock --pretty --stdout

run: ## Live chunked download (FILE_KEY=<key>, needs FIGMA_TOKEN)
	node bin/figma-download.mjs --file-key $(FILE_KEY)

audit: typecheck test ## typecheck + test

vendor: ## Clone or fast-forward vendor/macos-keychain-env (keychain secret store; git-ignored)
	@if [ -d "$(KEYCHAIN_ENV_DIR)/.git" ]; then \
	  git -C "$(KEYCHAIN_ENV_DIR)" pull --ff-only --quiet && echo "$(KEYCHAIN_ENV_DIR) up to date ($$(git -C "$(KEYCHAIN_ENV_DIR)" rev-parse --short HEAD))" \
	    || echo "WARN: could not update $(KEYCHAIN_ENV_DIR); using the existing checkout"; \
	else \
	  mkdir -p "$(VENDOR_DIR)" && git clone --quiet --depth 1 --branch "$(KEYCHAIN_ENV_REF)" "$(KEYCHAIN_ENV_REPO)" "$(KEYCHAIN_ENV_DIR)" \
	    && echo "cloned $(KEYCHAIN_ENV_REPO) ($(KEYCHAIN_ENV_REF)) -> $(KEYCHAIN_ENV_DIR)"; \
	fi

secret: vendor ## Store one value in the keychain: make secret KEY=FIGMA_TOKEN (hidden prompt; never on argv)
	@[ -n "$(KEY)" ] || { echo "usage: make secret KEY=<$(subst $() ,|,$(KEYCHAIN_KEYS))>   (hidden prompt; the value never touches argv)"; exit 2; }
	$(KEYCHAIN_CLI) set "$(KEYCHAIN_SERVICE)" "$(KEY)"

secrets: vendor ## List which keychain items exist for this package (reads no values)
	@echo "keychain service: $(KEYCHAIN_SERVICE)"; for k in $(KEYCHAIN_KEYS); do \
	  if $(KEYCHAIN_CLI) has "$(KEYCHAIN_SERVICE)" "$$k" >/dev/null 2>&1; then echo "present  $$k"; else echo "missing  $$k"; fi; done

clean: ## Remove node_modules / out
	rm -rf node_modules out
