#!/bin/sh
# Build the gleepack OTP toolchain: OTP apps + rebar3 + Elixir, assembled
# from a full `make install` output with a denylist applied.
#
# Required env: OTP_VERSION, REBAR3_VERSION
# Optional env: ELIXIR_VERSION (default: 1.18.3)
# Output: /tmp/toolchain/ — zip this as otp-$OTP_VERSION.zip

set -xe

OTP_VERSION="${OTP_VERSION:?OTP_VERSION required}"
REBAR3_VERSION="${REBAR3_VERSION:?REBAR3_VERSION required}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.3}"

JOBS=$(nproc 2>/dev/null || echo 4)
OTP_SRC=/usr/src/otp
REBAR3_SRC=/usr/src/rebar3
ELIXIR_SRC=/usr/src/elixir
INSTALL_PREFIX=/tmp/otp-install
TOOLCHAIN_DIR=/tmp/toolchain

# --- Dependencies ---
apk add --no-cache \
    curl ca-certificates \
    perl clang libc-dev linux-headers make \
    ncurses-dev ncurses-static \
    libressl-dev \
    rsync zip

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

# --- Configure and build ---
# No dead-strip here: enif_* exports must survive so crypto_callback.so can link.
cd "$OTP_SRC"
ERL_TOP="$OTP_SRC" \
LIBS="/usr/lib/libcrypto.a" \
./configure \
    CC=clang \
    --prefix="$INSTALL_PREFIX" \
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

# -k: keep going past optional apps that fail to build
ERL_TOP="$OTP_SRC" make -j"$JOBS" -k TYPE=opt || true
ERL_TOP="$OTP_SRC" make install

# --- rebar3 ---
curl -fSL -o /tmp/rebar3-src.tar.gz \
    "https://github.com/erlang/rebar3/archive/${REBAR3_VERSION}.tar.gz"
mkdir -p "$REBAR3_SRC"
tar xzf /tmp/rebar3-src.tar.gz -C "$REBAR3_SRC" --strip-components=1
rm /tmp/rebar3-src.tar.gz

cd "$REBAR3_SRC"
PATH="$INSTALL_PREFIX/bin:$PATH" \
ERL_TOP="$OTP_SRC" \
HOME="$PWD" \
./bootstrap

# --- Elixir ---
curl -fSL -o /tmp/elixir-src.tar.gz \
    "https://github.com/elixir-lang/elixir/archive/v${ELIXIR_VERSION}.tar.gz"
mkdir -p "$ELIXIR_SRC"
tar xzf /tmp/elixir-src.tar.gz -C "$ELIXIR_SRC" --strip-components=1
rm /tmp/elixir-src.tar.gz

cd "$ELIXIR_SRC"
PATH="$INSTALL_PREFIX/bin:$PATH" make -j"$JOBS" compile

# --- Assemble toolchain ---
mkdir -p "$TOOLCHAIN_DIR/lib" "$TOOLCHAIN_DIR/bin"

# OTP apps: copy from install prefix, stripping -X.Y.Z version suffixes
for app_dir in "$INSTALL_PREFIX/lib/erlang/lib/"*/; do
    [ -d "$app_dir" ] || continue
    versioned=$(basename "$app_dir")
    # Strip trailing -X.Y.Z (e.g. stdlib-6.1 → stdlib)
    name=$(printf '%s' "$versioned" | sed 's/-[0-9][0-9.]*$//')
    cp -r "$app_dir" "$TOOLCHAIN_DIR/lib/$name"
done

# start.boot for booting without applications
cp "$INSTALL_PREFIX/lib/erlang/bin/no_dot_erlang.boot" "$TOOLCHAIN_DIR/start.boot"

# rebar3 apps from its _build output
for app_dir in "$REBAR3_SRC/_build/prod/lib/"*/; do
    [ -d "$app_dir" ] || continue
    app_name=$(basename "$app_dir")
    app_file="$app_dir/ebin/$app_name.app"
    [ -f "$app_file" ] || continue
    dest="$TOOLCHAIN_DIR/lib/$app_name"
    mkdir -p "$dest/ebin"
    cp "$app_dir/ebin/"*.beam "$app_dir/ebin/"*.app "$dest/ebin/" 2>/dev/null || true
    [ -d "$app_dir/priv" ] && cp -r "$app_dir/priv" "$dest/" || true
done

# Elixir apps (BEAM + .ex source, like the official distribution)
for app_dir in "$ELIXIR_SRC/lib/"*/; do
    [ -d "$app_dir/ebin" ] || continue
    app_name=$(basename "$app_dir")
    dest="$TOOLCHAIN_DIR/lib/$app_name"
    mkdir -p "$dest/ebin"
    cp "$app_dir/ebin/"*.beam "$app_dir/ebin/"*.app "$dest/ebin/" 2>/dev/null || true
    if [ -d "$app_dir/lib" ]; then
        rsync -a --include='*/' --include='*.ex' --exclude='*' \
            "$app_dir/lib/" "$dest/lib/"
    fi
done

# rebar3 binary
install "$REBAR3_SRC/rebar3" "$TOOLCHAIN_DIR/bin/rebar3"

# --- DENYLIST: strip everything we don't want ---
for dir_name in man doc obj c_src emacs info examples; do
    find "$TOOLCHAIN_DIR" -type d -name "$dir_name" -exec rm -rf {} + 2>/dev/null || true
done

# Remove src files except .hrl headers (needed for NIF compilation)
find "$TOOLCHAIN_DIR" -path "*/src/*" ! -name "*.hrl" -type f -delete
find "$TOOLCHAIN_DIR" -type d -name src | sort -r | xargs rmdir 2>/dev/null || true

# Remove native binaries (statically linked into the runtime)
find "$TOOLCHAIN_DIR" -name "*.so"     -type f -delete
find "$TOOLCHAIN_DIR" -name "*.a"      -type f -delete
find "$TOOLCHAIN_DIR" -name "Makefile" -type f -delete
find "$TOOLCHAIN_DIR" -name "*.mk"     -type f -delete

# --- Strip debug info from all BEAM files ---
"$INSTALL_PREFIX/bin/erl" -noshell \
    -eval "beam_lib:strip_release(\"$TOOLCHAIN_DIR\"), erlang:halt(0)."

echo "Toolchain assembled -> $TOOLCHAIN_DIR"
