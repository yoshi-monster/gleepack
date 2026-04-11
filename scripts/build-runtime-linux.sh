#!/bin/sh
# Build the gleepack runtime (statically-linked, dead-code-stripped beam.smp)
# for Alpine Linux (musl libc).
#
# Required env: OTP_VERSION
# Output: /tmp/gleepack — stripped beam.smp ready to package

set -xe

OTP_VERSION="${OTP_VERSION:?OTP_VERSION required}"

JOBS=$(nproc 2>/dev/null || echo 4)
OTP_SRC=/usr/src/otp

# --- Dependencies ---
apk add --no-cache \
    curl ca-certificates \
    perl clang libc-dev linux-headers make \
    ncurses-dev ncurses-static \
    libressl-dev zip

# --- OTP source ---
curl -fSL -o /tmp/otp-src.tar.gz \
    "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz"
mkdir -p "$OTP_SRC"
tar xzf /tmp/otp-src.tar.gz -C "$OTP_SRC" --strip-components=1
rm /tmp/otp-src.tar.gz

# Apply gleepack patches
cp otp/unix_prim_file.c        "$OTP_SRC/erts/emulator/nifs/unix/unix_prim_file.c"
cp otp/gleepack_vfs.h          "$OTP_SRC/erts/emulator/nifs/unix/gleepack_vfs.h"
cp otp/gleepack_entry.c        "$OTP_SRC/erts/emulator/sys/unix/erl_main.c"
cp otp/gleepack_vfs.h          "$OTP_SRC/erts/emulator/sys/unix/gleepack_vfs.h"
cp otp/sys_drivers.c           "$OTP_SRC/erts/emulator/sys/unix/sys_drivers.c"
cp otp/inet_gethost_native.erl "$OTP_SRC/lib/kernel/src/inet_gethost_native.erl"

# Wrap STATIC_NIF_LIBS with --whole-archive so all object files in crypto.a
# are included regardless of link order (ec_static.o is not directly referenced
# but contains symbols needed by ecdh_static.o and pkey_static.o).
# sed -i 's/\$(STATIC_NIF_LIBS)/-Wl,--whole-archive $(STATIC_NIF_LIBS) -Wl,--no-whole-archive/g' \
    # "$OTP_SRC/erts/emulator/Makefile.in"

# --- Configure ---
# Static libcrypto, dead code elimination via --gc-sections.
# Full static link: -static pulls in musl libc statically.
cd "$OTP_SRC"
ERL_TOP="$OTP_SRC" \
CFLAGS="-Os -fdata-sections -ffunction-sections" \
LDFLAGS="-static -static-libgcc -l/usr/lib/libcrypto.a" \
./configure \
    CC=clang \
    --enable-jit \
    --with-termcap \
    --without-javac \
    --with-ssl=/usr \
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

# Pass 1: build emulator so enif_* exports exist for crypto_callback build
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/erts/emulator" TYPE=opt

# Build crypto NIF against the emulator's exports
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/lib/crypto/c_src" TYPE=opt

# Pass 2: remove beam.smp to force a relink that pulls in crypto.a + libcrypto.a
find "$OTP_SRC/bin" \( -name "beam.smp" -o -name "beam.jit" \) -delete
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/erts/emulator" TYPE=opt

# Copy and strip
BEAM=$(find "$OTP_SRC/bin" -name "beam.smp" -type f | head -1)
strip "$BEAM"
cp "$BEAM" /tmp/gleepack

echo "gleepack runtime -> /tmp/gleepack"
