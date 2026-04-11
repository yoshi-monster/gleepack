#!/bin/bash
# Build the gleepack runtime for Windows as a single static exe.
# Uses WSL + MSVC (via otp_build). Patches the emulator Makefile.in to link
# beam as a static exe instead of a DLL, using LIBCMT (static CRT).
#
# Usage: build-runtime-windows.sh <repo-path-in-wsl>
# Required env: OTP_VERSION
# Output: /mnt/c/gleepack/gleepack.exe — single static Windows executable

set -xe

OTP_VERSION="${OTP_VERSION:?OTP_VERSION required}"
OTP_ARCH="${OTP_ARCH:-x64}"   # x64 or arm64, passed from workflow matrix
REPO="${1:?repo path required}"
JOBS=$(($(nproc) + 2))

# OTP source must live on the Windows filesystem — otp_build requires it
OTP_SRC=/mnt/c/otp-src
OUT_DIR=/mnt/c/gleepack
# vcpkg triplet matches the otp_build arch name
VCPKG_TRIPLET="${OTP_ARCH}-windows-static"
SSL_PREFIX="C:/vcpkg/installed/${VCPKG_TRIPLET}"

mkdir -p "$OUT_DIR"

# --- OTP source ---
curl -fSL -o /tmp/otp-src.tar.gz \
    "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz"
mkdir -p "$OTP_SRC"
tar xzf /tmp/otp-src.tar.gz -C "$OTP_SRC" --strip-components=1
rm /tmp/otp-src.tar.gz

# Apply gleepack patches (Windows-specific files)
cp "$REPO/otp/win_prim_file.c"         "$OTP_SRC/erts/emulator/nifs/win32/win_prim_file.c"
cp "$REPO/otp/gleepack_vfs.h"          "$OTP_SRC/erts/emulator/nifs/win32/gleepack_vfs.h"
cp "$REPO/otp/gleepack_entry.c"        "$OTP_SRC/erts/emulator/sys/win32/erl_main.c"
cp "$REPO/otp/gleepack_vfs.h"          "$OTP_SRC/erts/emulator/sys/win32/gleepack_vfs.h"
cp "$REPO/otp/inet_gethost_native.erl" "$OTP_SRC/lib/kernel/src/inet_gethost_native.erl"

# --- Patch Makefile.in to produce a static exe instead of a DLL ---
#
# By default the Windows BEAM builds as beam.smp.dll (loaded dynamically by
# erl.exe via erlexec.dll). We want a single self-contained exe instead:
#   1. Change FLAVOR_EXECUTABLE / PRIMARY_EXECUTABLE targets from .dll → .exe
#   2. Replace the DLL link rule (-dll -def: -implib:) with a plain exe link
#   3. Use LIBCMT (static CRT) instead of MSVCRT (dynamic CRT)
python3 - <<'PYEOF'
import re, pathlib

p = pathlib.Path("erts/emulator/Makefile.in")
mk = p.read_text()

# 1. Rename beam targets from .dll to .exe
mk = mk.replace("beam$(TF_MARKER).dll",       "beam$(TF_MARKER).exe")
mk = mk.replace("beam$(TYPEMARKER).smp.dll",   "beam$(TYPEMARKER).smp.exe")

# 2. Replace the DLL link rule with a static exe link rule.
#    The original four-line rule inside ifeq ($(TARGET), win32):
old_rule = (
    "$(ld_verbose) $(LD) -dll -def:sys/$(ERLANG_OSTYPE)/erl.def \\\n"
    "\t-implib:$(BINDIR)/erl_dll.lib -o $@ \\\n"
    "\t$(LDFLAGS) $(DEXPORT) $(INIT_OBJS) $(OBJS) $(STATIC_NIF_LIBS) \\\n"
    "\t$(STATIC_DRIVER_LIBS) $(LIBS)"
)
new_rule = (
    "$(ld_verbose) $(LD) -lLIBCMT -o $@ \\\n"
    "\t$(LDFLAGS) $(DEXPORT) $(INIT_OBJS) $(OBJS) $(STATIC_NIF_LIBS) \\\n"
    "\t$(STATIC_DRIVER_LIBS) $(LIBS)"
)
assert old_rule in mk, "DLL link rule not found in Makefile.in — check OTP version"
mk = mk.replace(old_rule, new_rule)

p.write_text(mk)
print("Makefile.in patched: beam DLL → static exe, MSVCRT → LIBCMT")
PYEOF

# --- Set up MSVC environment and configure ---
cd "$OTP_SRC"
export ERL_TOP="$(pwd)"
export MAKEFLAGS="-j${JOBS}"
export ERLC_USE_SERVER=true
export ERTS_SKIP_DEPEND=true

eval "$(./otp_build env_win32 "$OTP_ARCH")"

./otp_build configure \
    --with-ssl="$SSL_PREFIX" \
    --disable-dynamic-ssl-lib \
    --enable-static-nifs \
    --enable-static-drivers \
    --without-wx \
    --without-debugger \
    --without-observer \
    --without-docs \
    --without-odbc \
    --without-et

# --- Two-pass emulator build (same rationale as Linux/macOS) ---

# Pass 1: build emulator so crypto NIF can link against enif_* exports
make -j"$JOBS" -C erts/emulator opt

# Build crypto NIF against the emulator
make -j"$JOBS" -C lib/crypto/c_src opt

# Pass 2: remove beam to force a relink that pulls in crypto + libcrypto
find bin -name "beam*.exe" -o -name "beam*.dll" | xargs rm -f
make -j"$JOBS" -C erts/emulator opt

# --- Copy result ---
# gleepack_entry.c replaces erl_main.c, which compiles into the beam exe.
# After our Makefile.in patch, the output is beam.smp.exe — a single static binary.
BEAM=$(find bin -name "beam.smp.exe" -type f | head -1)
cp "$BEAM" "$OUT_DIR/gleepack.exe"

echo "gleepack runtime -> $OUT_DIR/gleepack.exe"
