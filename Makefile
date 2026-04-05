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

configure: $(BUILD_ROOT)/configured
$(BUILD_ROOT)/configured: $(OTP_SRC)
	cd $(OTP_SRC) && LDFLAGS="-Wl,-dead_strip" ./configure \
		--without-wx \
		--without-javac \
		--without-odbc \
		--without-jinterface \
		--disable-parallel-configure
	touch $(BUILD_ROOT)/configured

build: $(BUILD_ROOT)/gleepack
$(BUILD_ROOT)/gleepack: $(BUILD_ROOT)/configured $(BUILD_ROOT)/patched
	ERL_TOP=$(CURDIR)/$(OTP_SRC) $(MAKE) -C $(OTP_SRC)/erts/emulator TYPE=opt
	BEAM=$$(find $(OTP_SRC)/bin -name beam.smp -type f | head -1) && \
	 strip $$BEAM && \
	 cp $$BEAM $(BUILD_ROOT)/gleepack
	@echo "beam.smp -> $(BUILD_ROOT)/gleepack"

# Start an Erlang shell using our patched beam.
# Uses the system OTP's boot files and stdlib (kernel, stdlib, etc.) since we only
# build the emulator, not the full OTP release. The patched gleepack intercept is
# active — opening a /__gleepack__/ path will log to stderr.
shell:
	@test -f $(BUILD_ROOT)/gleepack || (echo "Run 'make build' first"; exit 1)
	ROOTDIR=$(ERTS_ROOT) $(BUILD_ROOT)/gleepack -- \
		-root $(ERTS_ROOT) \
		-progname erl \
		-boot $(ERTS_ROOT)/bin/start_clean \
		-home $(HOME) \
		-start_epmd false \
		-dist_listen false

# Build the test hello_world release using rebar3, then package it as a ZIP
# appended to build/gleepack to produce a self-contained test binary.
test-release: $(TEST_BINARY)

$(TEST_BINARY): $(BUILD_ROOT)/gleepack $(TEST_APP_DIR)/rebar.config $(TEST_APP_DIR)/src/hello_world.erl
	cd $(TEST_APP_DIR) && rebar3 release
	erl -noshell -eval \
		'Beams = filelib:wildcard("$(CURDIR)/$(TEST_REL_DIR)/lib/**/*.beam"), \
		 lists:foreach(fun(F) -> beam_lib:strip(F) end, Beams), \
		 erlang:halt(0).'
	rm -f $(BUILD_ROOT)/test-release.zip
	cd $(TEST_REL_DIR) && zip -qr $(CURDIR)/$(BUILD_ROOT)/test-release.zip lib releases
	cp $(BUILD_ROOT)/gleepack $@
	cat $(BUILD_ROOT)/test-release.zip >> $@
	chmod +x $@
	@echo "Built: $@"
	@echo "Run with: make test-run"

test-run: $(TEST_BINARY)
	$(TEST_BINARY)

clean-otp:
	rm -rf $(BUILD_ROOT)/*
