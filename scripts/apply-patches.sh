#!/bin/sh
# Apply gleepack patches to an OTP source tree.
# Required env: OTP_SRC, REPO_ROOT

set -xe

OTP_SRC="${OTP_SRC:?OTP_SRC required}"
REPO_ROOT="${REPO_ROOT:?REPO_ROOT required}"

# Unix
cp "$REPO_ROOT/otp/unix_prim_file.c"        "$OTP_SRC/erts/emulator/nifs/unix/unix_prim_file.c"
cp "$REPO_ROOT/otp/gleepack_vfs.h"          "$OTP_SRC/erts/emulator/nifs/unix/gleepack_vfs.h"
cp "$REPO_ROOT/otp/gleepack_entry.c"        "$OTP_SRC/erts/emulator/sys/unix/erl_main.c"
cp "$REPO_ROOT/otp/gleepack_vfs.h"          "$OTP_SRC/erts/emulator/sys/unix/gleepack_vfs.h"
cp "$REPO_ROOT/otp/sys_drivers.c"           "$OTP_SRC/erts/emulator/sys/unix/sys_drivers.c"

# Windows
cp "$REPO_ROOT/otp/win_prim_file.c"         "$OTP_SRC/erts/emulator/nifs/win32/win_prim_file.c"
cp "$REPO_ROOT/otp/gleepack_vfs.h"          "$OTP_SRC/erts/emulator/nifs/win32/gleepack_vfs.h"
cp "$REPO_ROOT/otp/gleepack_entry.c"        "$OTP_SRC/erts/emulator/sys/win32/erl_main.c"
cp "$REPO_ROOT/otp/gleepack_vfs.h"          "$OTP_SRC/erts/emulator/sys/win32/gleepack_vfs.h"
# replaces #ifdef WINVER with #ifdef _WIN32 and fixes static linkage (see otp/win_public_key.c)
cp "$REPO_ROOT/otp/win_public_key.c"        "$OTP_SRC/lib/public_key/c_src/public_key.c"

# Common
cp "$REPO_ROOT/otp/inet_gethost_native.erl" "$OTP_SRC/lib/kernel/src/inet_gethost_native.erl"
