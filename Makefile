ZIG ?= zig
ARM64_TARGET ?= aarch64-linux-gnu

.DEFAULT_GOAL := build
.PHONY: build test release arm64 arm64-debug help

build: ## Build host binaries with Zig's default Debug optimization.
	$(ZIG) build

test: ## Run unit and CLI contract tests on the host.
	$(ZIG) build test

release: ## Build host binaries with ReleaseSafe optimization.
	$(ZIG) build -Doptimize=ReleaseSafe

arm64: ## Cross-compile ReleaseSafe binaries for Rocky Linux aarch64.
	$(ZIG) build -Dtarget=$(ARM64_TARGET) -Doptimize=ReleaseSafe

arm64-debug: ## Cross-compile Debug binaries for aarch64 development.
	$(ZIG) build -Dtarget=$(ARM64_TARGET) -Doptimize=Debug

help: ## Show available Make targets.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "%-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
