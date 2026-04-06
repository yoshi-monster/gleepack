import filepath
import gleam/bool
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import gleepack/config
import platform
import simplifile
import snag.{type Snag}

pub const targets = [
  Target(
    arch: platform.Arm64,
    os: platform.Darwin,
    otp_version: "28.4.1",
    extra: None,
    erts_hash: "TODO",
    otp_hash: "TODO",
  ),
]

pub opaque type Target {
  Target(
    arch: platform.Arch,
    os: platform.Os,
    otp_version: String,
    extra: Option(String),
    erts_hash: String,
    otp_hash: String,
  )
}

pub fn default() -> Result(Target, Nil) {
  let arch = platform.arch()
  let os = platform.os()

  list.filter(targets, fn(target) { target.os == os && target.arch == arch })
  |> list.max(fn(a, b) { string.compare(a.otp_version, b.otp_version) })
}

pub fn from_string(slug input: String) -> Result(Target, Nil) {
  list.find(targets, fn(target) { slug(target) == input })
}

pub fn matching_native(matching other_target: Target) -> Result(Target, Nil) {
  let arch = platform.arch()
  let os = platform.os()

  list.find(targets, fn(target) {
    target.os == os
    && target.arch == arch
    && target.otp_version == other_target.otp_version
  })
}

pub fn slug(target: Target) -> String {
  let arch = case target.arch {
    platform.Arm64 -> "aarch64"
    platform.X64 -> "amd64"

    unknown ->
      panic as {
        "Unknown arch "
        <> string.inspect(unknown)
        <> ". This is a bug in gleepack. Please open an issue!"
      }
  }

  let os = case target.os {
    platform.Darwin -> "macos"
    platform.Linux -> "linux"
    platform.Win32 -> "win32"

    unknown ->
      panic as {
        "Unknown arch "
        <> string.inspect(unknown)
        <> ". This is a bug in gleepack. Please open an issue!"
      }
  }

  case target.extra {
    Some(extra) ->
      arch <> "-" <> os <> "-otp-" <> target.otp_version <> "-" <> extra
    None -> arch <> "-" <> os <> "-otp-" <> target.otp_version
  }
}

pub type InstalledTarget {
  InstalledTarget(target: Target, runtime_binary: String, otp_directory: String)
}

pub fn installed() -> List(InstalledTarget) {
  let cache = config.cache_dir()
  list.filter_map(targets, fn(target) {
    let runtime_binary = runtime_binary_path(cache, target)
    let otp_directory = otp_dir_path(cache, target)
    case
      simplifile.is_file(runtime_binary),
      simplifile.is_directory(otp_directory)
    {
      Ok(True), Ok(True) ->
        Ok(InstalledTarget(target:, runtime_binary:, otp_directory:))
      _, _ -> Error(Nil)
    }
  })
}

pub fn install(target: Target) -> Result(InstalledTarget, Snag) {
  let cache = config.cache_dir()

  use runtime_binary <- result.try(
    install_runtime(cache, target)
    |> snag.context("Installing runtime " <> slug(target)),
  )

  use otp_directory <- result.try(
    install_otp(cache, target)
    |> snag.context("Installing OTP " <> target.otp_version),
  )

  Ok(InstalledTarget(target:, runtime_binary:, otp_directory:))
}

pub fn uninstall(target: Target) -> Result(Nil, Snag) {
  let cache = config.cache_dir()

  io.println(
    ansi.pink("   Removing") <> " " <> config.app_name <> " " <> slug(target),
  )

  use Nil <- result.try(
    simplifile.delete(runtime_dir_path(cache, target))
    |> snag.map_error(simplifile.describe_error),
  )

  // GC: only remove OTP if no other installed targets still use this version.
  let otp_still_needed =
    list.any(targets, fn(other) {
      other.otp_version == target.otp_version
      && simplifile.is_directory(runtime_dir_path(cache, other)) == Ok(True)
    })

  use Nil <- result.try(case otp_still_needed {
    True -> Ok(Nil)
    False -> {
      io.println(ansi.pink("   Removing") <> " OTP " <> target.otp_version)
      simplifile.delete(otp_dir_path(cache, target))
      |> snag.map_error(simplifile.describe_error)
    }
  })

  io.println(
    ansi.pink("    Removed") <> " " <> config.app_name <> " " <> slug(target),
  )

  Ok(Nil)
}

fn install_runtime(cache_dir: String, target: Target) -> Result(String, Snag) {
  let runtime_path = runtime_binary_path(cache_dir, target)

  use Nil <- result.try(
    simplifile.create_directory_all(filepath.directory_name(runtime_path))
    |> snag.map_error(simplifile.describe_error),
  )

  use <- bool.guard(
    when: simplifile.is_file(runtime_path) == Ok(True),
    return: Ok(runtime_path),
  )

  io.println(
    ansi.pink("Downloading") <> " " <> config.app_name <> " " <> slug(target),
  )

  todo
  //
}

fn install_otp(cache_dir: String, target: Target) -> Result(String, Snag) {
  let otp_path = otp_dir_path(cache_dir, target)

  use <- bool.guard(
    when: simplifile.is_directory(otp_path) == Ok(True),
    return: Ok(otp_path),
  )

  io.println(ansi.pink("Downloading") <> " OTP " <> target.otp_version)

  todo
}

fn runtime_dir_path(cache_dir: String, target: Target) -> String {
  cache_dir
  |> filepath.join("runtime")
  |> filepath.join(slug(target))
}

fn runtime_binary_path(cache_dir: String, target: Target) -> String {
  runtime_dir_path(cache_dir, target)
  |> filepath.join(case target.os {
    platform.Win32 -> config.app_name <> ".exe"
    _ -> config.app_name
  })
}

fn otp_dir_path(cache_dir: String, target: Target) -> String {
  cache_dir
  |> filepath.join("otp")
  |> filepath.join(target.otp_version)
}
