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
import gleam/order
import gleam/result
import gleam/string
import gleam_community/ansi
import gleepack/config
import gleepack/zip
import platform.{type Arch, type Os}
import simplifile
import snag.{type Snag}

pub opaque type Target {
  Target(
    arch: Arch,
    os: Os,
    otp_version: String,
    extra: Option(String),
    runtime_link: String,
    runtime_hash: String,
    otp_link: String,
    otp_hash: String,
    revision: String,
  )
}

fn arch_to_string(arch: Arch) -> String {
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

fn os_to_string(os: Os) -> String {
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

fn arch_from_string(s: String) -> Result(Arch, Nil) {
  case s {
    "aarch64" -> Ok(platform.Arm64)
    "amd64" -> Ok(platform.X64)
    _ -> Error(Nil)
  }
}

fn os_from_string(s: String) -> Result(Os, Nil) {
  case s {
    "linux" -> Ok(platform.Linux)
    "macos" -> Ok(platform.Darwin)
    "win32" | "windows" -> Ok(platform.Win32)
    _ -> Error(Nil)
  }
}

fn arch_decoder() -> decode.Decoder(Arch) {
  use s <- decode.then(decode.string)
  case arch_from_string(s) {
    Ok(arch) -> decode.success(arch)
    Error(_) -> decode.failure(platform.Arm64, "Arch")
  }
}

fn os_decoder() -> decode.Decoder(Os) {
  use s <- decode.then(decode.string)
  case os_from_string(s) {
    Ok(os) -> decode.success(os)
    Error(_) -> decode.failure(platform.Linux, "Os")
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

const api_base = "https://api.github.com/repos/yoshi-monster/gleepack"

type GhAsset {
  GhAsset(name: String, url: String, digest: String)
}

type GhRelease {
  GhRelease(tag_name: String, target_commitish: String, assets: List(GhAsset))
}

fn gh_asset_decoder() -> decode.Decoder(GhAsset) {
  use name <- decode.field("name", decode.string)
  use url <- decode.field("browser_download_url", decode.string)
  use digest <- decode.field("digest", decode.string)
  decode.success(GhAsset(name:, url:, digest:))
}

fn gh_release_decoder() -> decode.Decoder(GhRelease) {
  use tag_name <- decode.field("tag_name", decode.string)
  use target_commitish <- decode.field("target_commitish", decode.string)
  use assets <- decode.field("assets", decode.list(gh_asset_decoder()))
  decode.success(GhRelease(tag_name:, target_commitish:, assets:))
}

fn gh_get(url: String) -> Result(String, Snag) {
  let assert Ok(req) = request.to(url)
  let req = request.set_header(req, "accept", "application/vnd.github+json")
  use response <- result.try(
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.dispatch(req)
    |> snag.map_error(error_to_string)
    |> snag.context("GET " <> url),
  )
  Ok(response.body)
}

fn parse_asset_name(name: String) -> Result(#(Arch, Os, String), Nil) {
  use #(left, version_zip) <- result.try(string.split_once(name, "-otp-"))
  use arch_os <- result.try(case left {
    "gleepack-" <> rest -> Ok(rest)
    _ -> Error(Nil)
  })
  use #(arch_str, os_str) <- result.try(string.split_once(arch_os, "-"))
  use #(otp_version, rest) <- result.try(string.split_once(version_zip, ".zip"))
  use <- bool.guard(when: rest != "", return: Error(Nil))
  use arch <- result.try(arch_from_string(arch_str))
  use os <- result.try(os_from_string(os_str))
  Ok(#(arch, os, otp_version))
}

fn targets_for_release(release: GhRelease) -> List(Target) {
  let GhRelease(tag_name:, target_commitish: revision, assets:) = release
  case tag_name {
    "OTP-" <> release_otp_version -> {
      let otp_zip = "otp-" <> release_otp_version <> ".zip"
      case list.find(assets, fn(a) { a.name == otp_zip }) {
        Error(Nil) -> []
        Ok(otp_asset) ->
          list.filter_map(assets, fn(asset) {
            use #(arch, os, otp_version) <- result.try(parse_asset_name(
              asset.name,
            ))
            Ok(Target(
              arch:,
              os:,
              otp_version:,
              extra: None,
              runtime_link: asset.url,
              runtime_hash: asset.digest,
              otp_link: otp_asset.url,
              otp_hash: otp_asset.digest,
              revision:,
            ))
          })
      }
    }
    _ -> []
  }
}

pub fn available() -> Result(List(Target), Snag) {
  io.println(ansi.pink("  Resolving") <> " versions")
  let url = api_base <> "/releases"
  use body <- result.try(gh_get(url))
  use releases <- result.try(
    json.parse(body, decode.list(gh_release_decoder()))
    |> snag.replace_error("Failed to parse releases response"),
  )
  Ok(list.flat_map(releases, targets_for_release))
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

pub fn compare(a: Target, b: Target) -> order.Order {
  use <- order.lazy_break_tie(in: string.compare(b.otp_version, a.otp_version))
  use <- order.lazy_break_tie(in: string.compare(
    arch_to_string(a.arch),
    arch_to_string(b.arch),
  ))
  use <- order.lazy_break_tie(in: string.compare(
    os_to_string(a.os),
    os_to_string(b.os),
  ))
  order.Eq
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
  // TODO: can we use installed() here?
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
