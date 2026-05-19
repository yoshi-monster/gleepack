#!/bin/sh
# Build the gleepack OTP toolchain: OTP apps + rebar3 + Elixir, assembled
# from a full `make install` output with a denylist applied.
#
# Required env: OTP_VERSION, REBAR3_VERSION
# Optional env: ELIXIR_VERSION (default: 1.18.3)
# Output: ./build/toolchain/ - zip this as otp-$OTP_VERSION.zip

set -xe

OTP_VERSION="${OTP_VERSION:?OTP_VERSION required}"
REBAR3_VERSION="${REBAR3_VERSION:?REBAR3_VERSION required}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.3}"

JOBS=$(nproc 2>/dev/null || echo 4)
REPO_ROOT=$(pwd)
OTP_SRC="$REPO_ROOT/build/otp"
REBAR3_SRC="$REPO_ROOT/build/rebar3"
ELIXIR_SRC="$REPO_ROOT/build/elixir"
INSTALL_PREFIX="$REPO_ROOT/build/otp-install"
TOOLCHAIN_DIR="$REPO_ROOT/build/toolchain"

# --- Dependencies ---
if [ "${INSTALL_DEPS:-1}" = "1" ]; then
    apk add --no-cache \
        curl ca-certificates \
        perl clang libc-dev linux-headers make \
        ncurses-dev ncurses-static \
        libressl-dev \
        rsync zip
fi

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
OTP_SRC="$OTP_SRC" REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/scripts/apply-patches.sh"

# --- Configure and build ---
# No dead-strip here: enif_* exports must survive so crypto_callback.so can link.
cd "$OTP_SRC"
ERL_TOP="$OTP_SRC" \
./configure \
    CC=clang \
    --prefix="$INSTALL_PREFIX" \
    --enable-jit \
    --with-termcap \
    --without-javac \
    --with-ssl=/usr \
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
if [ ! -d "$REBAR3_SRC" ]; then
    mkdir -p "$REPO_ROOT/build"
    curl -fSL -o "$REPO_ROOT/build/rebar3-src.tar.gz" \
        "https://github.com/erlang/rebar3/archive/${REBAR3_VERSION}.tar.gz"
    mkdir -p "$REBAR3_SRC"
    tar xzf "$REPO_ROOT/build/rebar3-src.tar.gz" -C "$REBAR3_SRC" --strip-components=1
    rm "$REPO_ROOT/build/rebar3-src.tar.gz"
fi

cd "$REBAR3_SRC"
PATH="$INSTALL_PREFIX/bin:$PATH" \
ERL_TOP="$OTP_SRC" \
HOME="$PWD" \
ERL_COMPILER_OPTIONS="[nowarn_deprecated_catch,nowarn_match_alias_pats]" \
./bootstrap

# --- Elixir ---
if [ ! -d "$ELIXIR_SRC" ]; then
    mkdir -p "$REPO_ROOT/build"
    curl -fSL -o "$REPO_ROOT/build/elixir-src.tar.gz" \
        "https://github.com/elixir-lang/elixir/archive/v${ELIXIR_VERSION}.tar.gz"
    mkdir -p "$ELIXIR_SRC"
    tar xzf "$REPO_ROOT/build/elixir-src.tar.gz" -C "$ELIXIR_SRC" --strip-components=1
    rm "$REPO_ROOT/build/elixir-src.tar.gz"
fi

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

# start.boot: use the build-tree copy which already has version-free paths.
cp "$OTP_SRC/bin/no_dot_erlang.boot" "$TOOLCHAIN_DIR/start.boot"

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
