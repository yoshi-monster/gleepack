OTP_VERSION ?= 28.4.1
OTP_TAG     := OTP-$(OTP_VERSION)
BUILD_ROOT  := build
OTP_SRC     := $(BUILD_ROOT)/otp-$(OTP_VERSION)

# System OTP root and erts bin dir — used for boot files and stdlib when running a shell.
# Our custom beam.smp needs -root/-bindir to find kernel/stdlib/etc.
ERTS_ROOT := $(shell erl -eval 'io:format("~s",[code:root_dir()])' -noshell -s erlang halt 2>/dev/null)
ERTS_BIN  := $(shell ls -d $(ERTS_ROOT)/erts-*/bin 2>/dev/null | head -1)

.PHONY: all cli checkout patch configure build shell clean-otp

all: cli

cli:
	cd cli && gleam build

checkout: $(OTP_SRC)
$(OTP_SRC):
	git clone --depth=1 --branch=$(OTP_TAG) https://github.com/erlang/otp.git $(OTP_SRC)

patch: $(BUILD_ROOT)/patched
$(BUILD_ROOT)/patched: $(OTP_SRC)
	cp otp/unix_prim_file.c $(OTP_SRC)/erts/emulator/nifs/unix/unix_prim_file.c
	cp otp/gleepack_entry.c $(OTP_SRC)/erts/emulator/sys/unix/erl_main.c
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
	BINDIR=$(ERTS_BIN) ROOTDIR=$(ERTS_ROOT) $(BUILD_ROOT)/gleepack -- \
		-root $(ERTS_ROOT) \
		-bindir $(ERTS_BIN) \
		-progname erl \
		-boot $(ERTS_ROOT)/bin/start_clean \
		-home $(HOME) \
		-start_epmd false \
		-dist_listen false

clean-otp:
	rm -rf $(BUILD_ROOT)/*
