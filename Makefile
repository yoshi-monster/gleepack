JOBS := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

OTP_VERSION ?= 28.4.1
OTP_TAG     := OTP-$(OTP_VERSION)
BUILD_ROOT  := build
OTP_SRC     := $(BUILD_ROOT)/otp-$(OTP_VERSION)

TEST_APP_DIR     := test/hello_world
TEST_REL_DIR     := $(TEST_APP_DIR)/_build/default/rel/hello_world
TEST_BINARY      := $(BUILD_ROOT)/hello_world_test

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

# Sentinel files — written once after checkout, stable across configure/build runs.
# Using the source directory as a dependency causes spurious rebuilds because
# ./configure writes files (Makefile, config.h, etc.) directly into the source
# root, updating its mtime and making downstream sentinels appear stale.
OTP_CLONED    := $(BUILD_ROOT)/otp-cloned
OTP_BUILT     := $(BUILD_ROOT)/otp-built

# rebar3: Erlang build tool, needed to produce OTP releases
REBAR3_VERSION ?= 3.24.0
REBAR3_TAG     := $(REBAR3_VERSION)
REBAR3_SRC     := $(BUILD_ROOT)/rebar3-$(REBAR3_VERSION)
REBAR3_BIN     := $(BUILD_ROOT)/rebar3
REBAR3_CLONED  := $(BUILD_ROOT)/rebar3-cloned

# Elixir: needed for Mix releases and Elixir app support
ELIXIR_VERSION ?= 1.18.3
ELIXIR_TAG     := v$(ELIXIR_VERSION)
ELIXIR_SRC     := $(BUILD_ROOT)/elixir-$(ELIXIR_VERSION)
ELIXIR_CLONED  := $(BUILD_ROOT)/elixir-cloned

# Path to our custom OTP's bin directory (erl, erlc, etc.)
OTP_BIN := $(CURDIR)/$(OTP_SRC)/bin

# Single assembled toolchain directory: OTP apps + rebar3 apps + Elixir apps.
# install rsyncs this one directory — no separate install steps.
TOOLCHAIN_DIR       := $(BUILD_ROOT)/toolchain
TOOLCHAIN_ASSEMBLED := $(BUILD_ROOT)/toolchain-assembled

# TODO: Figure out what do to for real here.
OPENSSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null)

CONFIGURE_FLAGS = \
	--enable-jit \
	--with-termcap \
	--without-javac \
	--with-ssl=$(OPENSSL_PREFIX) \
	--disable-dynamic-ssl-lib \
	--enable-static-nifs \
	--enable-static-drivers \
	--without-wx \
	--without-debugger \
	--without-observer \
	--without-docs \
	--without-odbc \
	--without-et \
	--disable-parallel-configure

.PHONY: all cli checkout patch build otp assemble install shell \
        test-release test-run clean-otp \
        rebar3-checkout rebar3 elixir-checkout elixir \
        run-rebar3 run-mix run-iex

all: cli

cli:
	cd cli && gleam build

# --- OTP ---

checkout: $(OTP_CLONED)
$(OTP_CLONED):
	git clone --depth=1 --branch=$(OTP_TAG) https://github.com/erlang/otp.git $(OTP_SRC)
	touch $@

patch: $(BUILD_ROOT)/patched
$(BUILD_ROOT)/patched: $(OTP_CLONED) otp/unix_prim_file.c otp/gleepack_vfs.h otp/gleepack_entry.c otp/sys_drivers.c
	cp otp/unix_prim_file.c $(OTP_SRC)/erts/emulator/nifs/unix/unix_prim_file.c
	cp otp/gleepack_vfs.h   $(OTP_SRC)/erts/emulator/nifs/unix/gleepack_vfs.h
	cp otp/gleepack_entry.c $(OTP_SRC)/erts/emulator/sys/unix/erl_main.c
	cp otp/gleepack_vfs.h   $(OTP_SRC)/erts/emulator/sys/unix/gleepack_vfs.h
	cp otp/sys_drivers.c    $(OTP_SRC)/erts/emulator/sys/unix/sys_drivers.c
	touch $@

# Build beam.smp with -Wl,-dead_strip so the final binary is as small as possible.
# NIF/driver API symbols are fine to strip here since everything is statically linked in.
build: $(BUILD_ROOT)/gleepack
$(BUILD_ROOT)/gleepack: $(BUILD_ROOT)/patched
	cd $(OTP_SRC) && \
		LIBS="$(OPENSSL_PREFIX)/lib/libcrypto.a" \
		LDFLAGS="-Wl,-dead_strip" \
		./configure $(CONFIGURE_FLAGS)
	ERL_TOP=$(CURDIR)/$(OTP_SRC) $(MAKE) -j$(JOBS) -C $(OTP_SRC)/erts/emulator TYPE=opt
	BEAM=$$(find $(OTP_SRC)/bin -name beam.smp -type f | head -1) && \
	 strip $$BEAM && \
	 cp $$BEAM $(BUILD_ROOT)/gleepack
	@echo "beam.smp -> $(BUILD_ROOT)/gleepack"

# Build all OTP lib apps. Configured WITHOUT -Wl,-dead_strip so that beam.smp
# retains its enif_*/erl_drv_* exports, allowing NIF/driver .so files to link.
# Depends on build so that the dead-stripped gleepack binary is already copied
# before this configure overwrites the source tree's configuration.
otp: $(OTP_BUILT)
$(OTP_BUILT): $(BUILD_ROOT)/gleepack
	cd $(OTP_SRC) && \
		LIBS="$(OPENSSL_PREFIX)/lib/libcrypto.a" \
		./configure $(CONFIGURE_FLAGS)
	ERL_TOP=$(CURDIR)/$(OTP_SRC) $(MAKE) -j$(JOBS) -k -C $(OTP_SRC) TYPE=opt || true
	touch $@
	@echo "OTP built -> $(OTP_SRC)/lib"

# --- rebar3 from source ---

rebar3-checkout: $(REBAR3_CLONED)
$(REBAR3_CLONED):
	git clone --depth=1 --branch=$(REBAR3_TAG) https://github.com/erlang/rebar3.git $(REBAR3_SRC)
	touch $@

# Bootstrap rebar3 using our custom OTP. The bootstrap script calls erl/erlc
# so we prepend our OTP bin dir to PATH. ERL_TOP tells the toolchain where to
# find includes and lib apps (compiler, stdlib, kernel, etc.).
rebar3: $(REBAR3_BIN)
$(REBAR3_BIN): $(REBAR3_CLONED) $(OTP_BUILT)
	cd $(REBAR3_SRC) && \
		PATH="$(OTP_BIN):$$PATH" \
		ERL_TOP="$(CURDIR)/$(OTP_SRC)" \
		./bootstrap
	cp $(REBAR3_SRC)/rebar3 $(REBAR3_BIN)
	@echo "rebar3 -> $(REBAR3_BIN)"

# --- Elixir from source ---

elixir-checkout: $(ELIXIR_CLONED)
$(ELIXIR_CLONED):
	git clone --depth=1 --branch=$(ELIXIR_TAG) https://github.com/elixir-lang/elixir.git $(ELIXIR_SRC)
	touch $@

# Build Elixir using our custom OTP. Elixir's Makefile picks up erl/erlc
# from PATH. We skip docs and install targets since we only need the compiled
# BEAM files from lib/*/ebin/.
elixir: $(BUILD_ROOT)/elixir-built
$(BUILD_ROOT)/elixir-built: $(ELIXIR_CLONED) $(OTP_BUILT)
	cd $(ELIXIR_SRC) && \
		PATH="$(OTP_BIN):$$PATH" \
		$(MAKE) -j$(JOBS) compile
	touch $@
	@echo "Elixir built -> $(ELIXIR_SRC)/lib"

# --- Assemble single toolchain release ---
#
# Produces build/toolchain/lib/ containing:
#   OTP apps       — beam/app/boot/script only, versioned dirs from source tree
#   rebar3 apps    — beam/app/priv from _build/prod/lib/, versioned from .app
#   Elixir apps    — beam/app + lib/*.ex (like official distribution), versioned
#
# All BEAM files are stripped of debug info. This single directory is what
# gets rsync'd by `make install` — no separate install steps.
assemble: $(TOOLCHAIN_ASSEMBLED)
$(TOOLCHAIN_ASSEMBLED): $(OTP_BUILT) $(REBAR3_BIN) $(BUILD_ROOT)/elixir-built
	rm -rf $(TOOLCHAIN_DIR)
	mkdir -p $(TOOLCHAIN_DIR)/lib $(TOOLCHAIN_DIR)/bin
	@# OTP apps: only beam/app/boot/script — no src, docs, examples, native drivers
	rsync -a \
	  --include='*/' \
	  --include='*.beam' \
	  --include='*.app' \
	  --include='*.script' \
	  --include='*.boot' \
	  --exclude='*' \
	  $(OTP_SRC)/lib/ $(TOOLCHAIN_DIR)/lib/
	@# start_clean.boot — needed to boot the VM without any specific application
	cp $(OTP_SRC)/bin/start_clean.boot $(TOOLCHAIN_DIR)/bin/
	@# rebar3 apps from _build/prod/lib/ — beam/app/priv only
	@for app_dir in $(REBAR3_SRC)/_build/prod/lib/*; do \
	  app_name=$$(basename $$app_dir); \
	  app_file=$$app_dir/ebin/$$app_name.app; \
	  [ -f "$$app_file" ] || continue; \
	  dest=$(TOOLCHAIN_DIR)/lib/$$app_name; \
	  mkdir -p $$dest/ebin; \
	  cp $$app_dir/ebin/*.beam $$app_dir/ebin/*.app $$dest/ebin/ 2>/dev/null || true; \
	  [ -d $$app_dir/priv ] && cp -r $$app_dir/priv $$dest/ || true; \
	done
	@# Elixir apps from lib/ — beam/app + ex source (like official distribution)
	@for app_dir in $(ELIXIR_SRC)/lib/*; do \
	  app_name=$$(basename $$app_dir); \
	  [ -d $$app_dir/ebin ] || continue; \
	  dest=$(TOOLCHAIN_DIR)/lib/$$app_name; \
	  mkdir -p $$dest/ebin; \
	  cp $$app_dir/ebin/*.beam $$app_dir/ebin/*.app $$dest/ebin/ 2>/dev/null || true; \
	  if [ -d $$app_dir/lib ]; then \
	    rsync -a --include='*/' --include='*.ex' --exclude='*' $$app_dir/lib/ $$dest/lib/; \
	  fi; \
	done
	@# Strip debug info from all BEAM files in the assembled toolchain
	PATH="$(OTP_BIN):$$PATH" erl -noshell -eval \
	  'beam_lib:strip_release("$(CURDIR)/$(TOOLCHAIN_DIR)"), erlang:halt(0).'
	touch $@
	@echo "Toolchain assembled -> $(TOOLCHAIN_DIR)"

# Install the gleepack binary and the assembled toolchain into the cache.
# Installation is a single rsync — no separate OTP / rebar3 / Elixir steps.
install:
	@CACHE="$$HOME/Library/Application Support/gleepack"; \
	 RUNTIME_DIR="$$CACHE/runtime/$(RUNTIME_SLUG)"; \
	 OTP_DIR="$$CACHE/otp/$(OTP_VERSION)"; \
	 mkdir -p "$$RUNTIME_DIR" "$$OTP_DIR" && \
	 cp $(BUILD_ROOT)/gleepack "$$RUNTIME_DIR/gleepack" && \
	 chmod +x "$$RUNTIME_DIR/gleepack" && \
	 rsync -a $(TOOLCHAIN_DIR)/ "$$OTP_DIR/" && \
	 echo "Installed runtime   -> $$RUNTIME_DIR/gleepack" && \
	 echo "Installed toolchain -> $$OTP_DIR"

# Build the test hello_world release using rebar3, then package it as a ZIP
# appended to build/gleepack to produce a self-contained test binary.
test-release: $(TEST_BINARY)

$(TEST_BINARY): $(BUILD_ROOT)/gleepack $(TEST_APP_DIR)/rebar.config $(TEST_APP_DIR)/src/hello_world.erl otp/erl_inetrc $(REBAR3_BIN)
	cd $(TEST_APP_DIR) && \
		PATH="$(OTP_BIN):$$PATH" \
		ERL_TOP="$(CURDIR)/$(OTP_SRC)" \
		$(CURDIR)/$(REBAR3_BIN) release
	chmod -R u+w "$(CURDIR)/$(TEST_REL_DIR)"
	PATH="$(OTP_BIN):$$PATH" erl -noshell -eval \
		 'beam_lib:strip_release("$(CURDIR)/$(TEST_REL_DIR)"), \
		 Others = filelib:wildcard("$(CURDIR)/$(TEST_REL_DIR)/lib/**/*.{c,h,erl,hrl,src,so}"), \
		 lists:foreach(fun file:delete/1, Others), \
		 Dirs = lists:reverse(lists:sort(filelib:wildcard("$(CURDIR)/$(TEST_REL_DIR)/lib/**/"))), \
		 lists:foreach(fun(D) -> file:del_dir(D) end, Dirs), \
		 erlang:halt(0).'
	cp otp/erl_inetrc $(TEST_REL_DIR)/erl_inetrc
	mv $(TEST_REL_DIR)/releases/1.0.0/start.boot $(TEST_REL_DIR)
	rm -fr $(TEST_REL_DIR)/releases
	rm -f $(BUILD_ROOT)/test-release.zip
	cd $(TEST_REL_DIR) && zip -qr $(CURDIR)/$(BUILD_ROOT)/test-release.zip lib erl_inetrc start.boot
	cp $(BUILD_ROOT)/gleepack $@
	cat $(BUILD_ROOT)/test-release.zip >> $@
	chmod +x $@
	@echo "Built: $@"
	@echo "Run with: make test-run"

test-run: $(TEST_BINARY)
	$(TEST_BINARY)

# Usage: make run-rebar3 ARGS="new app myapp"
ARGS ?=
run-rebar3:
	$(CURDIR)/$(BUILD_ROOT)/gleepack -- \
	    -root $(CURDIR)/$(TOOLCHAIN_DIR) \
	    -bindir $(CURDIR)/$(TOOLCHAIN_DIR) \
	    -home $(HOME) \
	    -boot $(CURDIR)/$(TOOLCHAIN_DIR)/bin/start_clean \
		-noshell \
	    -eval 'rebar3:main(init:get_plain_arguments()), erlang:halt(0).' \
	    -extra $(ARGS)

# Usage: make run-mix ARGS="new app my_app"
run-mix:
	$(CURDIR)/$(BUILD_ROOT)/gleepack -- \
	    -root $(CURDIR)/$(TOOLCHAIN_DIR) \
	    -bindir $(CURDIR)/$(TOOLCHAIN_DIR) \
	    -home $(HOME) \
	    -boot $(CURDIR)/$(TOOLCHAIN_DIR)/bin/start_clean \
	    -noshell \
	    -elixir_root $(CURDIR)/$(TOOLCHAIN_DIR)/lib \
	    -s elixir start_cli \
	    -elixir ansi_enabled true \
	    -extra --eval "Mix.CLI.main()" -- $(ARGS)

run-iex:
	$(CURDIR)/$(BUILD_ROOT)/gleepack -- \
	    -root $(CURDIR)/$(TOOLCHAIN_DIR) \
	    -bindir $(CURDIR)/$(TOOLCHAIN_DIR) \
	    -home $(HOME) \
	    -boot $(CURDIR)/$(TOOLCHAIN_DIR)/bin/start_clean \
	    -elixir_root $(CURDIR)/$(TOOLCHAIN_DIR)/lib \
	    -user elixir \
	    -elixir ansi_enabled true \
		-extra --no-halt

clean-otp:
	rm -rf $(BUILD_ROOT)/*
