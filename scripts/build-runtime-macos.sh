#!/bin/sh
# Build the gleepack runtime (dead-stripped beam.smp) for macOS.
#
# Required env: OTP_VERSION
# Output: ./build/runtime/gleepack - stripped beam.smp ready to package

set -xe

OTP_VERSION="${OTP_VERSION:?OTP_VERSION required}"

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
REPO_ROOT=$(pwd)
OTP_SRC="$REPO_ROOT/build/otp"
RUNTIME_OUT="$REPO_ROOT/build/runtime"

# --- Dependencies ---
if [ "${INSTALL_DEPS:-1}" = "1" ]; then
    brew install libressl
fi

SSL_PREFIX=$(brew --prefix libressl)

# --- OTP source ---
if [ ! -d "$OTP_SRC" ]; then
    mkdir -p "$REPO_ROOT/build"
    curl -fSL -o "$REPO_ROOT/build/otp-src.tar.gz" \
        "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz"
    mkdir -p "$OTP_SRC"
    tar xzf "$REPO_ROOT/build/otp-src.tar.gz" -C "$OTP_SRC" --strip-components=1
    rm "$REPO_ROOT/build/otp-src.tar.gz"
fi

# Apply gleepack patches
cp otp/unix_prim_file.c        "$OTP_SRC/erts/emulator/nifs/unix/unix_prim_file.c"
cp otp/gleepack_vfs.h          "$OTP_SRC/erts/emulator/nifs/unix/gleepack_vfs.h"
cp otp/gleepack_entry.c        "$OTP_SRC/erts/emulator/sys/unix/erl_main.c"
cp otp/gleepack_vfs.h          "$OTP_SRC/erts/emulator/sys/unix/gleepack_vfs.h"
cp otp/sys_drivers.c           "$OTP_SRC/erts/emulator/sys/unix/sys_drivers.c"
cp otp/inet_gethost_native.erl "$OTP_SRC/lib/kernel/src/inet_gethost_native.erl"

# --- Configure ---
# -Wl,-dead_strip removes unreachable code after final link (macOS linker flag).
cd "$OTP_SRC"
ERL_TOP="$OTP_SRC" \
LIBS="$SSL_PREFIX/lib/libcrypto.a" \
LDFLAGS="-Wl,-dead_strip" \
./configure \
    --enable-jit \
    --with-termcap \
    --without-javac \
    --with-ssl="$SSL_PREFIX" \
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

# Pre-build crypto.a — only needs erl_nif.h, not the emulator binary.
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/lib/crypto/c_src" TYPE=opt static_lib

# Build emulator — crypto.a is already present so it links in statically.
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/erts/emulator" TYPE=opt

# Copy and strip
BEAM=$(find "$OTP_SRC/bin" -name "beam.smp" -type f | head -1)
strip "$BEAM"
mkdir -p "$RUNTIME_OUT"
cp "$BEAM" "$RUNTIME_OUT/gleepack"

echo "gleepack runtime -> $RUNTIME_OUT/gleepack"
