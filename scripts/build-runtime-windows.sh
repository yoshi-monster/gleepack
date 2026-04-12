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
echo "=== vcpkg SSL lib dir ==="
ls -la "${SSL_LIB_DIR}/" 2>&1 || true
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

find "${SSL_PREFIX}"

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

cd "$OTP_SRC"

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

# 4. Patch crypto_callback.c: when building a static NIF, __declspec(dllexport)
#    on get_crypto_callbacks conflicts with the plain extern declaration in the
#    header (no DLLEXPORT there under !HAVE_DYNAMIC_CRYPTO_LIB). MSVC raises
#    C2375 "redefinition; different linkage". Strip the dllexport annotation
#    when STATIC_ERLANG_NIF is defined.
cb = pathlib.Path("lib/crypto/c_src/crypto_callback.c")
src = cb.read_text()
old_dllexport = "#ifdef __WIN32__\n#  define DLLEXPORT __declspec(dllexport)\n"
new_dllexport = (
    "#ifdef __WIN32__\n"
    "#  ifdef STATIC_ERLANG_NIF\n"
    "#    define DLLEXPORT\n"
    "#  else\n"
    "#    define DLLEXPORT __declspec(dllexport)\n"
    "#  endif\n"
)
assert old_dllexport in src, "DLLEXPORT block not found in crypto_callback.c — check OTP version"
cb.write_text(src.replace(old_dllexport, new_dllexport))
print("crypto_callback.c patched: DLLEXPORT → empty for STATIC_ERLANG_NIF builds")

# 5. Patch public_key/c_src/Makefile to add a static_lib target.
#    On Windows, public_key.dll depends on OpenSSL DLLs which don't exist in
#    our fully-static build.  Statically linking it into the emulator avoids
#    the runtime DLL load failure.  Linux/macOS .so files are self-contained so
#    they don't have this problem.  The Makefile.in ifeq(yes) block only covers
#    asn1+crypto, so we must add public_key explicitly.
pk = pathlib.Path("lib/public_key/c_src/Makefile")
pk_mk = pk.read_text()
static_lib_rule = """
static_lib: $(LIBDIR)/pubkey_os_cacerts.a

$(OBJDIR)/%_static.o: %.c
\t$(V_CC) -c $(DED_STATIC_CFLAGS) -o $@ $<

$(LIBDIR)/pubkey_os_cacerts.a: $(OBJDIR)/public_key_static.o
\t$(V_AR) $(AR_OUT)$@ $^
\t$(V_RANLIB) $@
"""
assert "static_lib" not in pk_mk, "public_key Makefile already has static_lib target"
pk.write_text(pk_mk + static_lib_rule)
print("public_key/c_src/Makefile patched: added static_lib target")
PYEOF

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
 

# Use --enable-static-nifs=yes so the emulator Makefile auto-discovers all NIFs
# (asn1, crypto, public_key, etc.) the same way as Linux/macOS builds.
# The only Windows-specific issue was asn1rt_nif.lib vs .a: the .a copy we
# create above (after `make static_lib`) makes the ifeq(yes) .a path work.
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
    --without-et \
    --without-docs

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
