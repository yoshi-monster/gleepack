import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleepack/io
import gleepack/project.{type Project, Gleam, Hex}
import gleepack/target.{type Target}
import snag.{type Snag}

// Bump this whenever package compilation or cache contents change in a way
// that is not represented by the inputs below.
const schema = "gleepack-package-cache-v3"

pub opaque type Cache {
  Cache(target: Target, keys: Dict(String, String))
}

pub type Status {
  Hit
  Miss
}

/// Prepare cache keys from packages in topological order.
pub fn new(
  packages: List(Project),
  target: Target,
  gleam_version: String,
) -> Cache {
  let keys =
    list.fold(packages, dict.new(), fn(keys, package) {
      case package {
        Gleam(source: Hex(outer_checksum:), name:, dependencies:, ..) ->
          case hex_key(outer_checksum, dependencies, keys, gleam_version) {
            Ok(key) -> dict.insert(keys, name, key)
            Error(Nil) -> keys
          }
        _ -> keys
      }
    })

  Cache(target:, keys:)
}

/// Return whether a package has a complete matching cache entry.
pub fn check(cache: Cache, package: Project) -> Result(Status, Snag) {
  case dict.get(cache.keys, package.name) {
    Error(Nil) -> Ok(Miss)
    Ok(key) -> {
      let cache_file = target.package_cache_key_path(cache.target, package.name)
      let ebin = target.package_ebin_dir(cache.target, package.name)

      use stored <- result.try(io.read_if_exists(cache_file))
      let app_file = filepath.join(ebin, package.otp_app <> ".app")

      case stored == Some(key) && io.file_exists(app_file) {
        True -> Ok(Hit)
        False -> Ok(Miss)
      }
    }
  }
}

/// Commit a cacheable package after all of its BEAM files were compiled.
pub fn commit(cache: Cache, name: String) -> Result(Nil, Snag) {
  case dict.get(cache.keys, name) {
    Error(Nil) -> Ok(Nil)
    Ok(key) -> io.write(target.package_cache_key_path(cache.target, name), key)
  }
}

// Returns None if any direct dependency is not cacheable.
fn hex_key(
  outer_checksum: String,
  dependencies: List(String),
  dependency_keys: Dict(String, String),
  gleam_version: String,
) -> Result(String, Nil) {
  case
    list.try_map(dependencies, fn(name) {
      dict.get(dependency_keys, name)
      |> result.map(fn(key) { name <> ":" <> key })
    })
  {
    Error(Nil) -> Error(Nil)
    Ok(dependency_keys) -> {
      let dependency_keys = list.sort(dependency_keys, string.compare)

      [schema, gleam_version, outer_checksum, ..dependency_keys]
      |> list.fold(crypto.new_hasher(crypto.Sha256), hash_string)
      |> crypto.digest
      |> bit_array.base16_encode
      |> string.lowercase
      |> Ok
    }
  }
}

fn hash_string(hasher: crypto.Hasher, value: String) -> crypto.Hasher {
  crypto.hash_chunk(hasher, <<value:utf8>>)
}
