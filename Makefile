JOBS := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

OTP_VERSION    ?= 29.0
REBAR3_VERSION ?= 3.24.0
ELIXIR_VERSION ?= 1.18.3

# Detect host platform to compute the target slug matching target.gleam's slug()
UNAME_M := $(shell uname -m)
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_M),arm64)
  HOST_ARCH := aarch64
else
  HOST_ARCH := amd64
endif
ifeq ($(UNAME_S),Darwin)
  HOST_OS := macos
else
  HOST_OS := linux
endif
RUNTIME_SLUG := $(HOST_ARCH)-$(HOST_OS)-otp-$(OTP_VERSION)

.PHONY: all cli runtime build-runtime-macos build-runtime-linux toolchain install clean

all: runtime toolchain cli

cli:
	gleam run build

# --- Runtime ---
# Dispatches to the platform-specific script; outputs ./build/runtime/gleepack.

ifeq ($(HOST_OS),macos)
runtime: build-runtime-macos
else
runtime: build-runtime-linux
endif

build-runtime-macos:
	OTP_VERSION=$(OTP_VERSION) INSTALL_DEPS=0 scripts/build-runtime-macos.sh

build-runtime-linux:
	OTP_VERSION=$(OTP_VERSION) INSTALL_DEPS=0 scripts/build-runtime-linux.sh

# --- Toolchain ---
# Builds OTP libs + rebar3 + Elixir via the Alpine script; outputs ./build/toolchain/.
# Intended to run inside a Docker container (the script uses apk).

toolchain:
	OTP_VERSION=$(OTP_VERSION) REBAR3_VERSION=$(REBAR3_VERSION) ELIXIR_VERSION=$(ELIXIR_VERSION) \
	    INSTALL_DEPS=0 scripts/build-toolchain.sh

# --- Install ---
# Copies build artefacts into the local cache. Skips components not yet built.
#   runtime  build/runtime/gleepack   -> ~/Library/Application Support/gleepack/runtime/<slug>/gleepack
#   toolchain build/toolchain/        -> ~/Library/Application Support/gleepack/otp/<version>/
#   cli      dist/gleepack-<slug>     -> ~/.local/bin/gleepack

copy-dev:
	@CACHE="$$HOME/Library/Application Support/gleepack"; \
	 RUNTIME_DIR="$$CACHE/runtime/$(RUNTIME_SLUG)"; \
	 OTP_DIR="$$CACHE/otp/$(OTP_VERSION)"; \
	 if [ -f build/runtime/gleepack ]; then \
	     mkdir -p "$$RUNTIME_DIR" && \
	     cp build/runtime/gleepack "$$RUNTIME_DIR/gleepack" && \
	     chmod +x "$$RUNTIME_DIR/gleepack" && \
	     echo "Installed runtime   -> $$RUNTIME_DIR/gleepack"; \
	 fi; \
	 if [ -d build/toolchain ]; then \
	     mkdir -p "$$OTP_DIR" && \
	     rsync -a build/toolchain/ "$$OTP_DIR/" && \
	     echo "Installed toolchain -> $$OTP_DIR"; \
	 fi; \
	 if [ -f dist/gleepack-$(RUNTIME_SLUG) ]; then \
	     mkdir -p "$$HOME/.local/bin" && \
	     cp dist/gleepack-$(RUNTIME_SLUG) "$$HOME/.local/bin/gleepack" && \
	     chmod +x "$$HOME/.local/bin/gleepack" && \
	     echo "Installed cli       -> $$HOME/.local/bin/gleepack"; \
	 fi

clean:
	rm -rf build/
