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

.PHONY: all cli checkout patch configure build shell test-release test-run clean-otp

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

# TODO: Figure out what do to for real heree.
OPENSSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null)

configure: $(BUILD_ROOT)/configured
$(BUILD_ROOT)/configured: $(OTP_SRC)
	cd $(OTP_SRC) && \
		LIBS="$(OPENSSL_PREFIX)/lib/libcrypto.a" \
		LDFLAGS="-Wl,-dead_strip" \
		./configure \
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
			--disable-parallel-configure
	touch $(BUILD_ROOT)/configured

build: $(BUILD_ROOT)/gleepack
$(BUILD_ROOT)/gleepack: $(BUILD_ROOT)/configured $(BUILD_ROOT)/patched
	ERL_TOP=$(CURDIR)/$(OTP_SRC) $(MAKE) -C $(OTP_SRC)/erts/emulator TYPE=opt
	BEAM=$$(find $(OTP_SRC)/bin -name beam.smp -type f | head -1) && \
	 strip $$BEAM && \
	 cp $$BEAM $(BUILD_ROOT)/gleepack
	@echo "beam.smp -> $(BUILD_ROOT)/gleepack"


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
		 erlang:halt(0).'
	cp otp/erl_inetrc $(TEST_REL_DIR)/erl_inetrc
	rm -f $(BUILD_ROOT)/test-release.zip
	cd $(TEST_REL_DIR) && zip -qr $(CURDIR)/$(BUILD_ROOT)/test-release.zip lib releases erl_inetrc
	cp $(BUILD_ROOT)/gleepack $@
	cat $(BUILD_ROOT)/test-release.zip >> $@
	chmod +x $@
	@echo "Built: $@"
	@echo "Run with: make test-run"

test-run: $(TEST_BINARY)
	$(TEST_BINARY)

clean-otp:
	rm -rf $(BUILD_ROOT)/*
