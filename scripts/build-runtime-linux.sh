#!/bin/sh
# Build the gleepack runtime (statically-linked, dead-code-stripped beam.smp)
# for Alpine Linux (musl libc).
#
# Required env: OTP_VERSION
# Output: /tmp/gleepack - stripped beam.smp ready to package

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

# Remove EMU_LDFLAGS from the emulator link line before configure runs.
# On x86-64 Linux, OTP's configure sets EMU_LDFLAGS to -Wl,-z,max-page-size=2097152
# for Transparent Huge Page support, forcing 2MB ELF segment alignment and adding
# ~2MB of zero-padding to the binary. EMU_LDFLAGS comes after our LDFLAGS in the
# link command so it can't be overridden via configure; patching Makefile.in before
# configure runs is the only reliable way (patching the generated Makefile doesn't
# stick because make regenerates it via config.status).
# EMU_LDFLAGS only ever contains THP flags; it's empty on non-x86-64 platforms.
sed -i 's/ \$(EMU_LDFLAGS)//' "$OTP_SRC/erts/emulator/Makefile.in"

# --- Configure ---
# Static libcrypto, dead code elimination via --gc-sections.
# Full static link: -static pulls in musl libc statically.
# -ffunction-sections -fdata-sections: put each symbol in its own ELF section
# so --gc-sections can eliminate unreferenced ones (equivalent to -dead_strip on macOS).
# -O2: optimize for speed; --gc-sections handles binary size.
cd "$OTP_SRC"
ERL_TOP="$OTP_SRC" \
./configure \
    CC=clang \
    CXX=clang \
    LIBS="-lncursesw -lssl -lcrypto -ltinfo -lstdc++" \
    CFLAGS="-O2 -ffunction-sections -fdata-sections" \
    LDFLAGS="-static -static-libgcc -static-libstdc++ -Wl,--gc-sections" \
    --enable-jit \
    --with-termcap \
    --without-javac \
    --with-ssl \
    --disable-dynamic-ssl-lib \
    --enable-static-nifs \
    --enable-builtin-zlib \
    --enable-static-drivers \
    --without-wx \
    --without-debugger \
    --without-observer \
    --without-docs \
    --without-odbc \
    --without-et \
    --without-docs \
    --disable-pie

# Pre-build crypto.a before the emulator passes.
# The emulator Makefile has a multi-target rule for static NIFs that, with -jN,
# spawns concurrent `make static_lib` jobs that race on crypto.a (file truncation).
# Building the archive first means make finds it already present and skips the rule.
# This works before the emulator exists: compiling the archive only needs erl_nif.h
# (a header), not the emulator binary's enif link-time exports.
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/lib/crypto/c_src" TYPE=opt static_lib

# Pass 1: build emulator objects (crypto.a already exists, no race)
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/erts/emulator" TYPE=opt

# Pass 2: remove beam.smp to force a relink that pulls in crypto.a + libcrypto.a
find "$OTP_SRC/bin" \( -name "beam.smp" -o -name "beam.jit" \) -delete
ERL_TOP="$OTP_SRC" make -j"$JOBS" -C "$OTP_SRC/erts/emulator" TYPE=opt

# Copy and strip
BEAM=$(find "$OTP_SRC/bin" -name "beam.smp" -type f | head -1)
strip "$BEAM"
cp "$BEAM" /tmp/gleepack

echo "gleepack runtime -> /tmp/gleepack"
