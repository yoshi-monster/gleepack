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
# VCPKG_INSTALLATION_ROOT is passed from Windows via WSLENV (auto-converted to WSL path).
# Fall back to /mnt/c/vcpkg if not set.
VCPKG_ROOT="${VCPKG_INSTALLATION_ROOT:-/mnt/c/vcpkg}"
# Use WSL path: configure checks with bash test -d; cc.sh converts to Windows path for MSVC
SSL_PREFIX="${VCPKG_ROOT}/installed/${VCPKG_TRIPLET}"

mkdir -p "$OUT_DIR"

# OTP configure looks for libcrypto.lib / libssl.lib in $ssl_root/lib/.
# vcpkg LibreSSL may name them crypto.lib / ssl.lib, or put them in lib/manual-link/.
# Find whichever exists and copy to the expected name.
SSL_LIB_DIR="${SSL_PREFIX}/lib"
STATIC_LIB_DIR="${SSL_LIB_DIR}/VC/$OTP_ARCH/MD"
mkdir -p "${STATIC_LIB_DIR}"
for name in crypto libcrypto; do
    src=$(find "${SSL_LIB_DIR}" -name "${name}.lib" -not -path "*/debug/*" 2>/dev/null | head -1)
    if [ -n "$src" ]; then
        cp -f "$src" "${STATIC_LIB_DIR}/libcrypto_static.lib"
        echo "Copied $src -> ${STATIC_LIB_DIR}/libcrypto_static.lib"
        break
    fi
done
for name in ssl libssl; do
    src=$(find "${SSL_LIB_DIR}" -name "${name}.lib" -not -path "*/debug/*" 2>/dev/null | head -1)
    if [ -n "$src" ]; then
        cp -f "$src" "${STATIC_LIB_DIR}/libssl_static.lib"
        echo "Copied $src -> ${STATIC_LIB_DIR}/libssl_static.lib"
        break
    fi
done

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
# public_key.c: replace #ifdef WINVER with #ifdef _WIN32 and fix static linkage
# (see otp/win_public_key.c for full rationale)
cp "$REPO/otp/win_public_key.c"        "$OTP_SRC/lib/public_key/c_src/public_key.c"

cd "$OTP_SRC"

# Apply build-system patches (DLL→EXE, static NIFs, public_key static_lib).
# Must run from $OTP_SRC; see scripts/patch-otp-windows.py for full rationale.
python3 "$REPO/scripts/patch-otp-windows.py"

# --- Set up MSVC environment and configure ---
export ERL_TOP="$(pwd)"
export MAKEFLAGS="-j${JOBS}"
export ERLC_USE_SERVER=true
export ERTS_SKIP_DEPEND=true

eval "$(./otp_build env_win32 "$OTP_ARCH")"

# lib/* static-NIF Makefiles check USING_VC (not MIXED_VC from otp.mk) to
# decide whether AR_FLAGS should be empty (VC) or "rc" (GNU ar). The emulator
# Makefile sets USING_VC=@MIXED_VC@ in its own scope but does not export it
# to sub-makes. Without it, ar.sh passes "rc" as an input file to link.exe
# /lib, causing LNK1181.
export USING_VC=yes

# otp_build env_win32 sets INCLUDE/LIB for the target arch but may not add
# the MSVC cross-compiler binary directory to PATH. Find it via vswhere and
# prepend it so cc.sh can invoke the correct cl.exe.
if [ "$OTP_ARCH" = "arm64" ]; then
    ARM64_CL=$(find "/mnt/c/Program Files/Microsoft Visual Studio" \
        -name "cl.exe" -path "*/Hostx64/arm64/cl.exe" 2>/dev/null | head -1)
    if [ -n "$ARM64_CL" ]; then
        export PATH="$(dirname "$ARM64_CL"):$PATH"
    else
        echo "ERROR: ARM64 MSVC cross-compiler (Hostx64/arm64/cl.exe) not found under /mnt/c/Program Files/Microsoft Visual Studio" >&2
        exit 1
    fi
fi

# LIBS flows through configure into @LIBS@ in every generated Makefile, so
# everything here ends up on the emulator link line.
#
# - bcrypt.lib crypt32.lib ws2_32.lib: required by LibreSSL static libs
# - libcrypto_static.lib libssl_static.lib: OpenSSL symbols needed by crypto.a
# - ole32.lib: CoTaskMemFree / SHGetKnownFolderPath used by gleepack_entry.c
export LIBS="${STATIC_LIB_DIR}/libcrypto_static.lib ${STATIC_LIB_DIR}/libssl_static.lib bcrypt.lib crypt32.lib ws2_32.lib ole32.lib"

# Explicit NIF list: asn1rt_nif.a, crypto.a, pubkey_os_cacerts.a.
# These are pre-built by the static_lib steps below before the emulator links.
# asn1rt_nif.a is a copy of the .lib (see comment near that cp command).
./otp_build configure \
    --enable-jit \
    --with-ssl="$SSL_PREFIX" \
    --disable-dynamic-ssl-lib \
    --enable-static-nifs="${OTP_SRC}/lib/asn1/priv/lib/win32/asn1rt_nif.a,${OTP_SRC}/lib/crypto/priv/lib/win32/crypto.a,${OTP_SRC}/lib/public_key/priv/lib/win32/pubkey_os_cacerts.a" \
    --enable-static-drivers \
    --enable-builtin-zlib \
    --without-wx \
    --without-debugger \
    --without-observer \
    --without-docs \
    --without-odbc \
    --without-et

# --- Two-pass emulator build (same rationale as Linux/macOS) ---

# Pre-build static NIF libs before the emulator passes.
# The emulator Makefile.in has a multi-target rule:
#   $(STATIC_NIF_LIBS) $(STATIC_DRIVER_LIBS):
#       (cd lib/ && make static_lib)
# GNU Make runs that recipe once per target, so with -jN the two targets
# (asn1rt_nif.lib and crypto.a) trigger concurrent make static_lib invocations
# that race on the same .o files, causing LNK1104. Building first ensures the
# files exist so make skips the rule during the emulator passes.
make -j"$JOBS" -C lib BUILD_STATIC_LIBS=1 TYPE=opt static_lib

# public_key/c_src is not reached by the top-level lib/ static_lib sweep because
# public_key's Makefile does not forward the static_lib target to its c_src subdir.
# Build it explicitly so pubkey_os_cacerts.a exists before the emulator links.
make -C lib/public_key/c_src static_lib

# make_driver_tab strips the .a suffix and _nif suffix from the basename to
# derive the symbol name, then appends _nif_init.  For asn1rt_nif.lib the
# .lib branch strips _nif.* → "asn1rt" → expects "asn1rt_nif_init".
# But ERL_NIF_INIT(asn1rt_nif,...) without STATIC_ERLANG_NIF_LIBNAME exports
# "asn1rt_nif_nif_init".  The colon override syntax only works for .a files.
# Fix: create a stub .a that just contains the .lib objects (link.exe /lib can
# produce an archive), then name it asn1rt_nif.a so make_driver_tab sees
# "asn1rt_nif" → generates "asn1rt_nif_nif_init" which matches the export.
cp lib/asn1/priv/lib/win32/asn1rt_nif.lib lib/asn1/priv/lib/win32/asn1rt_nif.a

# Single-pass emulator build. On Windows, crypto.a is already built by the
# pre-build step above and linked statically via STATIC_NIF_LIBS. The two-pass
# Unix dance (build emulator → build crypto.so → relink) is not needed here:
# the DLL build would fail anyway because libcrypto_static.lib pulls in
# BCryptGenRandom which is only in bcrypt.lib — a dep we carry in the emulator
# LIBS, not in the DLL link command.
make -j"$JOBS" -C erts/emulator opt

# --- Copy result ---
# gleepack_entry.c replaces erl_main.c, which compiles into the beam exe.
# After our Makefile.in patch, the output is beam.smp.exe — a single static binary.
BEAM=$(find bin -name "beam.smp.exe" -type f | head -1)
cp "$BEAM" "$OUT_DIR/gleepack.exe"

echo "gleepack runtime -> $OUT_DIR/gleepack.exe"
