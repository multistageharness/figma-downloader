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

.DEFAULT_GOAL := help

.PHONY: help install sdk typecheck test audit mock run clean

help: ## Show this help
	@echo "figma-downloader (Node twin) targets:"
	@echo "  make sdk         build the workspace SDK packages this CLI depends on"
	@echo "  make test        build the SDK, then run the test suite (node --test, no network)"
	@echo "  make typecheck   node --check every source file"
	@echo "  make mock        chunked download of the built-in offline fixture -> stdout"
	@echo "  make run         live download FILE_KEY=<key> (needs FIGMA_TOKEN)"
	@echo "  make install     npm install (links @internal/figma-api-fetch-file)"
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

clean: ## Remove node_modules / out
	rm -rf node_modules out
