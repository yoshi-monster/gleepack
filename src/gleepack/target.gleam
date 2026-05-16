import filepath
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/io
import gleam/json
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
    revision: String,
  )
}

fn arch_to_string(arch: platform.Arch) -> String {
  case arch {
    platform.Arm64 -> "aarch64"
    platform.X64 -> "amd64"
    unknown ->
      panic as {
        "Unknown arch "
        <> string.inspect(unknown)
        <> ". This is a bug in gleepack. Please open an issue!"
      }
  }
}

fn os_to_string(os: platform.Os) -> String {
  case os {
    platform.Darwin -> "macos"
    platform.Linux -> "linux"
    platform.Win32 -> "win32"
    unknown ->
      panic as {
        "Unknown os "
        <> string.inspect(unknown)
        <> ". This is a bug in gleepack. Please open an issue!"
      }
  }
}

fn arch_decoder() -> decode.Decoder(platform.Arch) {
  use s <- decode.then(decode.string)
  case s {
    "aarch64" -> decode.success(platform.Arm64)
    "amd64" -> decode.success(platform.X64)
    _ -> decode.failure(platform.Arm64, "Arch")
  }
}

fn os_decoder() -> decode.Decoder(platform.Os) {
  use s <- decode.then(decode.string)
  case s {
    "macos" -> decode.success(platform.Darwin)
    "linux" -> decode.success(platform.Linux)
    "win32" -> decode.success(platform.Win32)
    _ -> decode.failure(platform.Linux, "Os")
  }
}

fn target_to_json(target: Target) -> json.Json {
  let Target(
    arch:,
    os:,
    otp_version:,
    extra:,
    runtime_link:,
    runtime_hash:,
    otp_link:,
    otp_hash:,
    revision:,
  ) = target
  json.object([
    #("arch", json.string(arch_to_string(arch))),
    #("os", json.string(os_to_string(os))),
    #("otp_version", json.string(otp_version)),
    #("extra", case extra {
      None -> json.null()
      Some(value) -> json.string(value)
    }),
    #("runtime_link", json.string(runtime_link)),
    #("runtime_hash", json.string(runtime_hash)),
    #("otp_link", json.string(otp_link)),
    #("otp_hash", json.string(otp_hash)),
    #("revision", json.string(revision)),
  ])
}

fn target_decoder() -> decode.Decoder(Target) {
  use arch <- decode.field("arch", arch_decoder())
  use os <- decode.field("os", os_decoder())
  use otp_version <- decode.field("otp_version", decode.string)
  use extra <- decode.field("extra", decode.optional(decode.string))
  use runtime_link <- decode.field("runtime_link", decode.string)
  use runtime_hash <- decode.field("runtime_hash", decode.string)
  use otp_link <- decode.field("otp_link", decode.string)
  use otp_hash <- decode.field("otp_hash", decode.string)
  use revision <- decode.field("revision", decode.string)

  decode.success(Target(
    arch:,
    os:,
    otp_version:,
    extra:,
    runtime_link:,
    runtime_hash:,
    otp_link:,
    otp_hash:,
    revision:,
  ))
}

pub fn available() -> Result(List(Target), Snag) {
  io.println(ansi.pink("  Resolving") <> " versions")
  [
    Target(
      arch: platform.Arm64,
      os: platform.Linux,
      otp_version: "29.0",
      extra: None,
      runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/gleepack-aarch64-linux-otp-29.0.zip",
      runtime_hash: "sha256:d66be407064ae92d1a54bdb11eb3da22179167d5ff710926f13fd32c72c41416",
      otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/otp-29.0.zip",
      otp_hash: "sha256:ed93a14274032b2521aaf63e117721fe2481f28a5080b6897dc34bc6f7de5a85",
      revision: "25f11fddd2f87f6af5efb5b3f70f62a30548afd9",
    ),
    Target(
      arch: platform.Arm64,
      os: platform.Darwin,
      otp_version: "29.0",
      extra: None,
      runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/gleepack-aarch64-macos-otp-29.0.zip",
      runtime_hash: "sha256:bed60d59722303cd779eacd5ce10434fa9fe89257426a366b4544af4167ff476",
      otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/otp-29.0.zip",
      otp_hash: "sha256:ed93a14274032b2521aaf63e117721fe2481f28a5080b6897dc34bc6f7de5a85",
      revision: "25f11fddd2f87f6af5efb5b3f70f62a30548afd9",
    ),
    Target(
      arch: platform.X64,
      os: platform.Linux,
      otp_version: "29.0",
      extra: None,
      runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/gleepack-amd64-linux-otp-29.0.zip",
      runtime_hash: "sha256:c2ff6a49fe5de5e2cbe0fcd2f9097016280176a69eaf996290eb313935cb836a",
      otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/otp-29.0.zip",
      otp_hash: "sha256:ed93a14274032b2521aaf63e117721fe2481f28a5080b6897dc34bc6f7de5a85",
      revision: "25f11fddd2f87f6af5efb5b3f70f62a30548afd9",
    ),
    Target(
      arch: platform.X64,
      os: platform.Win32,
      otp_version: "29.0",
      extra: None,
      runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/gleepack-amd64-windows-otp-29.0.zip",
      runtime_hash: "sha256:e072d62881b482da20819cebb55b83b96a552031a38f239e2a7f7b0a70cfcb9f",
      otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-29.0/otp-29.0.zip",
      otp_hash: "sha256:ed93a14274032b2521aaf63e117721fe2481f28a5080b6897dc34bc6f7de5a85",
      revision: "25f11fddd2f87f6af5efb5b3f70f62a30548afd9",
    ),
    Target(
      arch: platform.Arm64,
      os: platform.Linux,
      otp_version: "28.4.2",
      extra: None,
      runtime_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/gleepack-aarch64-linux-otp-28.4.2.zip",
      runtime_hash: "sha256:0f6e4d427d5e4ad246f6f9493ef05156d96e1d371eca8d5e6ea7a5a4929fbf65",
      otp_link: "https://github.com/yoshi-monster/gleepack/releases/download/OTP-28.4.2/otp-28.4.2.zip",
      otp_hash: "sha256:3ded1537c66b13f2e1387e8b494ec789b730d444c1b4ffe1a41207e914217b3b",
      revision: "508e29db2c797111529e6191ecaa156219891b86",
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
      revision: "508e29db2c797111529e6191ecaa156219891b86",
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
      revision: "508e29db2c797111529e6191ecaa156219891b86",
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
      revision: "508e29db2c797111529e6191ecaa156219891b86",
    ),
  ]
  |> Ok
}

pub fn default(available: List(Target)) -> Result(Target, Nil) {
  let arch = platform.arch()
  let os = platform.os()

  list.filter(available, fn(t) { t.os == os && t.arch == arch })
  |> list.max(fn(a, b) { string.compare(a.otp_version, b.otp_version) })
}

pub fn from_string(
  available: List(Target),
  slug input: String,
) -> Result(Target, Nil) {
  list.find(available, fn(t) { slug(t) == input })
}

pub fn matching_native(
  available: List(Target),
  matching other_target: Target,
) -> Result(Target, Nil) {
  let arch = platform.arch()
  let os = platform.os()

  list.find(available, fn(t) {
    t.os == os && t.arch == arch && t.otp_version == other_target.otp_version
  })
}

pub fn supported(target: Target) -> Bool {
  target.arch == platform.arch() && target.os == platform.os()
}

pub fn slug(target: Target) -> String {
  let arch = arch_to_string(target.arch)
  let os = os_to_string(target.os)
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

pub fn installed() -> Result(List(InstalledTarget), Snag) {
  let cache = config.cache_dir()
  let runtime_base = filepath.join(cache, "runtime")

  use dirs <- result.try(case simplifile.read_directory(runtime_base) {
    Error(simplifile.Enoent) -> Ok([])
    other -> other |> snag.map_error(simplifile.describe_error)
  })

  use acc, dir_name <- list.try_fold(dirs, [])
  let json_path =
    filepath.join(runtime_base, dir_name) |> filepath.join("target.json")

  case simplifile.read(json_path) {
    Error(simplifile.Enoent) -> Ok(acc)
    other -> {
      use json_str <- result.try(
        other |> snag.map_error(simplifile.describe_error),
      )
      use target <- result.try(
        json.parse(json_str, target_decoder())
        |> snag.replace_error("Invalid target.json")
        |> snag.context(dir_name),
      )

      let runtime_binary = runtime_binary_path(cache, target)
      let otp_directory = otp_dir_path(cache, target)

      case
        simplifile.is_file(runtime_binary),
        simplifile.is_directory(otp_directory)
      {
        Ok(True), Ok(True) ->
          Ok([InstalledTarget(target:, runtime_binary:, otp_directory:), ..acc])
        _, _ -> Ok(acc)
      }
    }
  }
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
  let runtime_base = filepath.join(cache, "runtime")
  use otp_still_needed <- result.try(
    case simplifile.read_directory(runtime_base) {
      Error(simplifile.Enoent) -> Ok(False)
      other -> {
        use dirs <- result.try(
          other |> snag.map_error(simplifile.describe_error),
        )
        list.try_fold(dirs, False, fn(acc, dir_name) {
          let json_path =
            filepath.join(runtime_base, dir_name)
            |> filepath.join("target.json")
          case simplifile.read(json_path) {
            Error(simplifile.Enoent) -> Ok(acc)
            other -> {
              use s <- result.try(
                other |> snag.map_error(simplifile.describe_error),
              )
              json.parse(s, target_decoder())
              |> result.map(fn(t) { acc || t.otp_version == target.otp_version })
              |> snag.replace_error("Invalid target.json")
              |> snag.context(dir_name)
            }
          }
        })
      }
    },
  )

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
  let json_path = filepath.join(target_dir, "target.json")

  // If the directory already exists but the revision is stale or absent,
  // remove it so that download() re-fetches rather than bailing out early.
  let is_stale = case simplifile.read(json_path) {
    Ok(target_json) ->
      case json.parse(target_json, target_decoder()) {
        Ok(installed) -> installed.revision != target.revision
        Error(_) -> True
      }
    Error(_) -> simplifile.is_directory(target_dir) == Ok(True)
  }

  use Nil <- result.try(case is_stale {
    True ->
      simplifile.delete(target_dir)
      |> snag.map_error(simplifile.describe_error)
    False -> Ok(Nil)
  })

  use Nil <- result.try({
    download("gleepack " <> slug(target), target_dir, link, hash)
  })

  use Nil <- result.try(
    simplifile.write(json_path, json.to_string(target_to_json(target)))
    |> snag.map_error(simplifile.describe_error),
  )

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
