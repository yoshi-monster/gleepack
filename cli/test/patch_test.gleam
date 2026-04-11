//// Tests for the OTP patch system (Phase 2).

import gleam/string
import simplifile

// PATCH-01: Patch files are real .c source files stored in this repo

pub fn patch_files_exist_test() {
  let assert Ok(True) = simplifile.is_file("../otp/unix_prim_file.c")
  let assert Ok(True) = simplifile.is_file("../otp/gleepack_entry.c")
  Nil
}

pub fn unix_prim_file_has_gleepack_intercept_test() {
  let assert Ok(contents) = simplifile.read("../otp/unix_prim_file.c")
  // efile_open is intercepted via GLEEPACK_PREFIX path checks
  assert string.contains(contents, "GLEEPACK_PREFIX")
  assert string.contains(contents, "__gleepack__")
  Nil
}

pub fn entry_point_calls_erl_start_test() {
  let assert Ok(contents) = simplifile.read("../otp/gleepack_entry.c")
  assert string.contains(contents, "sys_init_signal_stack")
  assert string.contains(contents, "erl_start")
  Nil
}

pub fn entry_point_initialises_vfs_test() {
  let assert Ok(contents) = simplifile.read("../otp/gleepack_entry.c")
  // Entry point now initialises the VFS from the embedded zip archive
  assert string.contains(contents, "vfs")
  assert string.contains(contents, "erl_start")
  Nil
}
