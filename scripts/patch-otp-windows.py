#!/usr/bin/env python3
"""Apply gleepack patches to OTP source for the Windows static build.

Must be run from the OTP source root (e.g. /mnt/c/otp-src).

Patches applied:
  1. erts/emulator/Makefile.in  — beam DLL → static exe, MSVCRT → LIBCMT
  2. lib/crypto/c_src/crypto_callback.c — DLLEXPORT stripped for static NIF builds
  3. lib/public_key/c_src/Makefile — adds static_lib target for pubkey_os_cacerts
"""

import pathlib

# 1. Patch erts/emulator/Makefile.in to produce a static exe instead of a DLL.
#
# By default the Windows BEAM builds as beam.smp.dll (loaded dynamically by
# erl.exe via erlexec.dll). We want a single self-contained exe instead:
#   a. Change FLAVOR_EXECUTABLE / PRIMARY_EXECUTABLE targets from .dll → .exe
#   b. Replace the DLL link rule (-dll -def: -implib:) with a plain exe link
#   c. Use LIBCMT (static CRT) instead of MSVCRT (dynamic CRT)
p = pathlib.Path("erts/emulator/Makefile.in")
mk = p.read_text()

mk = mk.replace("beam$(TF_MARKER).dll",       "beam$(TF_MARKER).exe")
mk = mk.replace("beam$(TYPEMARKER).smp.dll",   "beam$(TYPEMARKER).smp.exe")

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

# 2. Patch lib/crypto/c_src/crypto_callback.c.
#
# When building a static NIF, __declspec(dllexport) on get_crypto_callbacks
# conflicts with the plain extern declaration in the header (no DLLEXPORT there
# under !HAVE_DYNAMIC_CRYPTO_LIB). MSVC raises C2375 "redefinition; different
# linkage". Strip the dllexport annotation when STATIC_ERLANG_NIF is defined.
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

# 3. Patch lib/public_key/c_src/Makefile to add a static_lib target.
#
# On Windows, public_key.dll depends on OpenSSL DLLs which don't exist in our
# fully-static build. Statically linking pubkey_os_cacerts into the emulator
# avoids the runtime DLL load failure. Linux/macOS .so files are self-contained
# so they don't have this problem. The Makefile.in ifeq(yes) block only covers
# asn1+crypto, so we must add public_key explicitly.
#
# AR_OUT/-out: note: the static public_key/c_src/Makefile doesn't contain the
# ifeq ($(USING_VC),yes) block present in Makefile.in-generated files. Without
# it AR_OUT is empty, and ar.sh treats the output path as an input (LNK1181).
pk = pathlib.Path("lib/public_key/c_src/Makefile")
pk_mk = pk.read_text()
static_lib_rule = """
ifeq ($(USING_VC),yes)
AR_OUT=-out:
AR_FLAGS=
else
AR_OUT=
AR_FLAGS=rc
endif

static_lib: $(LIBDIR)/pubkey_os_cacerts.a

$(OBJDIR)/%_static.o: %.c
\t$(V_CC) -c $(DED_STATIC_CFLAGS) $(PUBKEY_INCLUDES) -I$(OBJDIR) -o $@ $<

$(LIBDIR)/pubkey_os_cacerts.a: $(OBJDIR)/public_key_static.o
\t$(V_AR) $(AR_FLAGS) $(AR_OUT)$@ $^
\t$(V_RANLIB) $@
"""
assert "static_lib" not in pk_mk, "public_key Makefile already has static_lib target"
pk.write_text(pk_mk + static_lib_rule)
print("public_key/c_src/Makefile patched: added static_lib target")
