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

# Sentinel file marking that OTP lib apps have been compiled.
OTP_BUILT := $(BUILD_ROOT)/otp-built

# rebar3: Erlang build tool, needed to produce OTP releases
REBAR3_VERSION ?= 3.24.0
REBAR3_TAG     := $(REBAR3_VERSION)
REBAR3_SRC     := $(BUILD_ROOT)/rebar3-$(REBAR3_VERSION)
REBAR3_BIN     := $(BUILD_ROOT)/rebar3

# Elixir: needed for Mix releases and Elixir app support
ELIXIR_VERSION ?= 1.18.3
ELIXIR_TAG     := v$(ELIXIR_VERSION)
ELIXIR_SRC     := $(BUILD_ROOT)/elixir-$(ELIXIR_VERSION)

# Path to our custom OTP's bin directory (erl, erlc, etc.)
OTP_BIN        := $(CURDIR)/$(OTP_SRC)/bin

# TODO: Figure out what do to for real heree.
OPENSSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null)

CONFIGURE_FLAGS = \
	--enable-jit \
	--without-termcap \
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

.PHONY: all cli checkout patch build otp install shell test-release test-run clean-otp rebar3-checkout rebar3-build elixir-checkout elixir-build install-tools

all: cli

cli:
	cd cli && gleam build

checkout: $(OTP_SRC)
$(OTP_SRC):
	git clone --depth=1 --branch=$(OTP_TAG) https://github.com/erlang/otp.git $(OTP_SRC)

patch: $(BUILD_ROOT)/patched
$(BUILD_ROOT)/patched: $(OTP_SRC) otp/unix_prim_file.c otp/gleepack_vfs.h otp/gleepack_entry.c otp/sys_drivers.c
	cp otp/unix_prim_file.c $(OTP_SRC)/erts/emulator/nifs/unix/unix_prim_file.c
	cp otp/gleepack_vfs.h   $(OTP_SRC)/erts/emulator/nifs/unix/gleepack_vfs.h
	cp otp/gleepack_entry.c $(OTP_SRC)/erts/emulator/sys/unix/erl_main.c
	cp otp/gleepack_vfs.h   $(OTP_SRC)/erts/emulator/sys/unix/gleepack_vfs.h
	cp otp/sys_drivers.c    $(OTP_SRC)/erts/emulator/sys/unix/sys_drivers.c
	touch $(BUILD_ROOT)/patched

# Build beam.smp with -Wl,-dead_strip so the final binary is as small as possible.
# NIF/driver API symbols are fine to strip here since everything is statically linked in.
build: $(BUILD_ROOT)/gleepack
$(BUILD_ROOT)/gleepack: $(BUILD_ROOT)/patched
	cd $(OTP_SRC) && \
		LIBS="$(OPENSSL_PREFIX)/lib/libcrypto.a" \
		LDFLAGS="-Wl,-dead_strip" \
		./configure $(CONFIGURE_FLAGS)
	ERL_TOP=$(CURDIR)/$(OTP_SRC) $(MAKE) -C $(OTP_SRC)/erts/emulator TYPE=opt
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
	ERL_TOP=$(CURDIR)/$(OTP_SRC) $(MAKE) -k -C $(OTP_SRC) TYPE=opt || true
	touch $(OTP_BUILT)
	@echo "OTP built -> $(OTP_SRC)/lib"

# Copy the runtime binary and OTP lib directory into the gleepack cache so that
# `gleepack installed` reports them as available without downloading.
# Only .beam/.app/.script/.boot are copied — no src, docs, or native drivers.
# .beam files are then stripped of debug info via beam_lib:strip_release/1.
install: $(BUILD_ROOT)/gleepack $(OTP_BUILT)
	@CACHE="$$HOME/Library/Application Support/gleepack"; \
	 RUNTIME_DIR="$$CACHE/runtime/$(RUNTIME_SLUG)"; \
	 OTP_DIR="$$CACHE/otp/$(OTP_VERSION)"; \
	 mkdir -p "$$RUNTIME_DIR" && \
	 cp $(BUILD_ROOT)/gleepack "$$RUNTIME_DIR/gleepack" && \
	 chmod +x "$$RUNTIME_DIR/gleepack" && \
	 mkdir -p "$$OTP_DIR/lib" && \
	 rsync -a \
	   --include='*/' \
	   --include='*.beam' \
	   --include='*.app' \
	   --include='*.script' \
	   --include='*.boot' \
	   --exclude='*' \
	   $(OTP_SRC)/lib/ "$$OTP_DIR/lib/" && \
	 PATH="$(OTP_BIN):$$PATH" erl -noshell -eval \
	   "beam_lib:strip_release(\"$$OTP_DIR\"), erlang:halt(0)." && \
	 echo "Installed runtime -> $$RUNTIME_DIR/gleepack" && \
	 echo "Installed OTP     -> $$OTP_DIR"


# --- rebar3 from source ---

rebar3-checkout: $(REBAR3_SRC)
$(REBAR3_SRC):
	git clone --depth=1 --branch=$(REBAR3_TAG) https://github.com/erlang/rebar3.git $(REBAR3_SRC)

# Bootstrap rebar3 using our custom OTP. The bootstrap script calls erl/erlc
# so we prepend our OTP bin dir to PATH. ERL_TOP tells the toolchain where to
# find includes and lib apps (compiler, stdlib, kernel, etc.).
rebar3-build: $(REBAR3_BIN)
$(REBAR3_BIN): $(REBAR3_SRC) $(OTP_BUILT)
	cd $(REBAR3_SRC) && \
		PATH="$(OTP_BIN):$$PATH" \
		ERL_TOP="$(CURDIR)/$(OTP_SRC)" \
		./bootstrap
	cp $(REBAR3_SRC)/rebar3 $(REBAR3_BIN)
	touch $(BUILD_ROOT)/rebar3-built
	@echo "rebar3 -> $(REBAR3_BIN)"

# --- Elixir from source ---

elixir-checkout: $(ELIXIR_SRC)
$(ELIXIR_SRC):
	git clone --depth=1 --branch=$(ELIXIR_TAG) https://github.com/elixir-lang/elixir.git $(ELIXIR_SRC)

# Build Elixir using our custom OTP. Elixir's Makefile picks up erl/erlc
# from PATH. We skip docs and install targets since we only need the compiled
# BEAM files from lib/*/ebin/.
elixir-build: $(BUILD_ROOT)/elixir-built
$(BUILD_ROOT)/elixir-built: $(ELIXIR_SRC) $(OTP_BUILT)
	cd $(ELIXIR_SRC) && \
		PATH="$(OTP_BIN):$$PATH" \
		$(MAKE) compile
	touch $(BUILD_ROOT)/elixir-built
	@echo "Elixir built -> $(ELIXIR_SRC)/lib"

# --- Install rebar3 + Elixir as OTP apps ---
#
# Copies BEAM files from rebar3's _build/default/lib/*/ebin/ and Elixir's
# lib/*/ebin/ into the OTP cache's lib/ directory. This makes them available
# as standard OTP applications invocable via -run.
# Also installs the rebar3 escript to otp/{version}/bin/ as a convenience.
# Also copies start_clean.boot from the OTP build.
install-tools: install $(REBAR3_BIN) $(BUILD_ROOT)/elixir-built
	@CACHE="$$HOME/Library/Application Support/gleepack"; \
	 OTP_DIR="$$CACHE/otp/$(OTP_VERSION)"; \
	 echo "Installing rebar3 BEAM apps..." && \
	 for app_ebin in $(REBAR3_SRC)/_build/default/lib/*/ebin; do \
	   app_name=$$(basename $$(dirname $$app_ebin)); \
	   mkdir -p "$$OTP_DIR/lib/$$app_name/ebin" && \
	   cp $$app_ebin/*.beam $$app_ebin/*.app "$$OTP_DIR/lib/$$app_name/ebin/" 2>/dev/null; \
	 done && \
	 echo "Installing Elixir BEAM apps..." && \
	 for elixir_app in $(ELIXIR_SRC)/lib/*/ebin; do \
	   app_name=$$(basename $$(dirname $$elixir_app)); \
	   version_suffix="$$app_name-$(ELIXIR_VERSION)"; \
	   mkdir -p "$$OTP_DIR/lib/$$version_suffix/ebin" && \
	   cp $$elixir_app/*.beam $$elixir_app/*.app "$$OTP_DIR/lib/$$version_suffix/ebin/" 2>/dev/null; \
	 done && \
	 mkdir -p "$$OTP_DIR/bin" && \
	 cp $(REBAR3_BIN) "$$OTP_DIR/bin/rebar3" && \
	 chmod +x "$$OTP_DIR/bin/rebar3" && \
	 BOOT=$$(find $(OTP_SRC)/lib/sasl/ebin -name 'start_clean.boot' 2>/dev/null || find $(OTP_SRC) -name 'start_clean.boot' -type f 2>/dev/null | head -1) && \
	 if [ -n "$$BOOT" ]; then cp "$$BOOT" "$$OTP_DIR/bin/start_clean.boot"; fi && \
	 echo "Installed rebar3 apps to $$OTP_DIR/lib/" && \
	 echo "Installed Elixir apps to $$OTP_DIR/lib/" && \
	 echo "Installed rebar3 escript to $$OTP_DIR/bin/rebar3"

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

clean-otp:
	rm -rf $(BUILD_ROOT)/*
