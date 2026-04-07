OTP_VERSION ?= 28.4.1
OTP_TAG     := OTP-$(OTP_VERSION)
BUILD_ROOT  := build
OTP_SRC     := $(BUILD_ROOT)/otp-$(OTP_VERSION)

# System OTP root — used for boot files and stdlib when running a shell.
# Our custom beam.smp needs -root to find kernel/stdlib/etc.
ERTS_ROOT := $(shell erl -eval 'io:format("~s",[code:root_dir()])' -noshell -s erlang halt 2>/dev/null)

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

.PHONY: all cli checkout patch build otp install shell test-release test-run clean-otp

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
	 erl -noshell -eval \
	   "beam_lib:strip_release(\"$$OTP_DIR\"), erlang:halt(0)." && \
	 echo "Installed runtime -> $$RUNTIME_DIR/gleepack" && \
	 echo "Installed OTP     -> $$OTP_DIR"


# Build the test hello_world release using rebar3, then package it as a ZIP
# appended to build/gleepack to produce a self-contained test binary.
test-release: $(TEST_BINARY)

$(TEST_BINARY): $(BUILD_ROOT)/gleepack $(TEST_APP_DIR)/rebar.config $(TEST_APP_DIR)/src/hello_world.erl otp/erl_inetrc
	cd $(TEST_APP_DIR) && rebar3 release
	chmod -R u+w "$(CURDIR)/$(TEST_REL_DIR)"
	erl -noshell -eval \
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
