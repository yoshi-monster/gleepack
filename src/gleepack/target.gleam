import filepath
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/http/request
import gleam/httpc
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import gleepack/config
import gleepack/zip
import platform
import simplifile
import snag.{type Snag}

pub opaque type Target {
  Target(
    arch: platform.Arch,
    os: platform.Os,
    otp_version: String,
    extra: Option(String),
    runtime_link: String,
    runtime_hash: String,
    otp_link: String,
    otp_hash: String,
  )
}

pub const targets = [
  Target(
    arch: platform.Arm64,
    os: platform.Linux,
    otp_version: "28.4.2",
    extra: None,
    runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/gleepack-aarch64-linux-otp-28.4.2.zip",
    runtime_hash: "sha256:0f6e4d427d5e4ad246f6f9493ef05156d96e1d371eca8d5e6ea7a5a4929fbf65",
    otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/otp-28.4.2.zip",
    otp_hash: "sha256:3ded1537c66b13f2e1387e8b494ec789b730d444c1b4ffe1a41207e914217b3b",
  ),
  Target(
    arch: platform.X64,
    os: platform.Linux,
    otp_version: "28.4.2",
    extra: None,
    runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/gleepack-amd64-linux-otp-28.4.2.zip",
    runtime_hash: "sha256:d8bcd9cb25557247c140ddf0bda5310740d98b7eba4fd65a793b23364a493625",
    otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/otp-28.4.2.zip",
    otp_hash: "sha256:3ded1537c66b13f2e1387e8b494ec789b730d444c1b4ffe1a41207e914217b3b",
  ),
  Target(
    arch: platform.Arm64,
    os: platform.Darwin,
    otp_version: "28.4.2",
    extra: None,
    runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/gleepack-aarch64-macos-otp-28.4.2.zip",
    runtime_hash: "sha256:8d39d5c853024b20dcd33ef34f1e12d0e2661374773785b6bcee1243c844ce11",
    otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/otp-28.4.2.zip",
    otp_hash: "sha256:3ded1537c66b13f2e1387e8b494ec789b730d444c1b4ffe1a41207e914217b3b",
  ),
  Target(
    arch: platform.X64,
    os: platform.Win32,
    otp_version: "28.4.2",
    extra: None,
    runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/gleepack-amd64-windows-otp-28.4.2.zip",
    runtime_hash: "sha256:12a9f880becb5b843034e25397e1a33f3725a22534e1d73c37b02e7218cd783a",
    otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/otp-28.4.2.zip",
    otp_hash: "sha256:3ded1537c66b13f2e1387e8b494ec789b730d444c1b4ffe1a41207e914217b3b",
  ),
]

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

pub fn supported(target: Target) -> Bool {
  target.arch == platform.arch() && target.os == platform.os()
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

pub fn otp_version(target: Target) {
  target.otp_version
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
  let Target(runtime_link: link, runtime_hash: hash, ..) = target
  let path = runtime_binary_path(cache_dir, target)
  let target_dir = filepath.directory_name(path)

  use Nil <- result.try({
    download("gleepack " <> slug(target), target_dir, link, hash)
  })

  Ok(path)
}

fn install_otp(cache_dir: String, target: Target) -> Result(String, Snag) {
  let Target(otp_version: vsn, otp_link: link, otp_hash: hash, ..) = target
  let path = otp_dir_path(cache_dir, target)

  use Nil <- result.try(download("OTP " <> vsn, path, link, hash))

  Ok(path)
}

fn download(label, target_dir, link, hash) {
  use <- bool.guard(
    when: simplifile.is_directory(target_dir) == Ok(True),
    return: Ok(Nil),
  )

  io.println(ansi.pink("Downloading") <> " " <> label)

  let assert Ok(request) =
    request.to(link) |> result.map(request.set_body(_, <<>>))

  use response <- result.try(
    httpc.configure()
    |> httpc.timeout(5 * 60 * 1000)
    |> httpc.follow_redirects(True)
    |> httpc.dispatch_bits(request)
    |> snag.map_error(error_to_string)
    |> snag.context("Downloading " <> link),
  )

  use Nil <- result.try(
    validate_hash(response.body, hash)
    |> snag.context("Verifying hash"),
  )

  use Nil <- result.try(
    simplifile.create_directory_all(target_dir)
    |> snag.map_error(simplifile.describe_error),
  )

  use _ <- result.try(
    zip.extract(response.body, target_dir)
    |> snag.map_error(zip.describe_error)
    |> snag.context("Extracting archive"),
  )

  io.println(ansi.pink(" Downloaded") <> " " <> label)

  Ok(Nil)
}

fn validate_hash(body: BitArray, hash: String) -> Result(Nil, Snag) {
  case hash {
    "sha256:" <> hex -> do_validate_hash(crypto.Sha256, body, hex)
    _ -> snag.error("Unsupported hash type: " <> hash)
  }
}

fn do_validate_hash(hash_algorithm, body, hex) {
  use expected <- result.try(
    bit_array.base16_decode(hex)
    |> snag.replace_error("Invalid expected hash: " <> hex),
  )

  let actual = crypto.hash(hash_algorithm, body)

  case crypto.secure_compare(expected, actual) {
    True -> Ok(Nil)
    False ->
      snag.error(
        "Hash mismatch: Expected "
        <> hex
        <> ", got "
        <> bit_array.base16_encode(actual),
      )
  }
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

fn error_to_string(error: httpc.HttpError) -> String {
  case error {
    httpc.InvalidUtf8Response -> "Invalid utf-8 body"
    httpc.FailedToConnect(ip4:, ip6: _) ->
      "Failed to connect: " <> connect_error_to_string(ip4)
    httpc.ResponseTimeout -> "Timeout"
  }
}

fn connect_error_to_string(error: httpc.ConnectError) -> String {
  case error {
    httpc.Posix(code:) -> code
    httpc.TlsAlert(code:, detail:) ->
      "TLS Error: " <> detail <> " (" <> code <> ")"
  }
}
