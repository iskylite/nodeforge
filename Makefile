ZIG ?= zig
LINUX_AMD64_TARGET ?= x86_64-linux-gnu
LINUX_ARM64_TARGET ?= aarch64-linux-gnu

.DEFAULT_GOAL := build
.PHONY: build test release \
        linux-amd64 linux-arm64 linux-arm64-debug \
        dist dist-linux-amd64 dist-linux-arm64 \
        help

build: ## Build host binaries with Zig's default Debug optimization.
	$(ZIG) build

test: ## Run unit and CLI contract tests on the host.
	$(ZIG) build test

release: ## Build host binaries with ReleaseSafe optimization.
	$(ZIG) build -Doptimize=ReleaseSafe

linux-amd64: ## Cross-compile ReleaseSafe binaries for Linux x86_64.
	$(ZIG) build -Dtarget=$(LINUX_AMD64_TARGET) -Doptimize=ReleaseSafe

linux-arm64: ## Cross-compile ReleaseSafe binaries for Linux aarch64.
	$(ZIG) build -Dtarget=$(LINUX_ARM64_TARGET) -Doptimize=ReleaseSafe

linux-arm64-debug: ## Cross-compile Debug binaries for Linux aarch64 development.
	$(ZIG) build -Dtarget=$(LINUX_ARM64_TARGET) -Doptimize=Debug

define package_dist
	@v=$$(sed -n 's/^const nodeforge_version = "\([^"]*\)";.*/\1/p' build.zig); \
	commit=$$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown); \
	date=$$(date -u +%Y%m%d); \
	pkg=nodeforge-v$$v-$$date+git$$commit-$(1); \
	mkdir -p dist/$$pkg; \
	cp zig-out/bin/nodeforge zig-out/bin/nodeforged zig-out/bin/nodeforge-initrd zig-out/bin/nodeforge-agent README.md LICENSE dist/$$pkg/; \
	cd dist && zip -rq $$pkg.zip $$pkg && rm -rf $$pkg; \
	echo "Packaged: dist/$$pkg.zip"
endef

dist: release ## Package host release binaries with README and LICENSE into dist/.
	$(call package_dist,$(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'))

dist-linux-amd64: linux-amd64 ## Cross-compile and package Linux x86_64 release binaries into dist/.
	$(call package_dist,amd64)

dist-linux-arm64: linux-arm64 ## Cross-compile and package Linux aarch64 release binaries into dist/.
	$(call package_dist,arm64)

help: ## Show available Make targets.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "%-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
