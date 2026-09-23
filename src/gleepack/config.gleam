import directories
import envoy
import filepath
import gleam/erlang/application
import gleam/result

pub const app_name = "gleepack"

pub const build_dir = "build/" <> app_name

pub const packages_dir = "build/packages"

pub type Error {
  NoCacheDirFound
}

pub fn describe_error(error: Error) -> String {
  case error {
    NoCacheDirFound ->
      "The enviroment variable `GLEEPACK_CACHE_DIR` and `LOCALAPPDATA` are not set. At least one is required."
  }
}

pub fn cache_dir() -> Result(String, Error) {
  case envoy.get("GLEEPACK_CACHE_DIR") {
    Ok(dir) -> Ok(dir)
    Error(_) -> {
      use base <- result.try(
        directories.data_local_dir() |> result.replace_error(NoCacheDirFound),
      )
      Ok(filepath.join(base, app_name))
    }
  }
}

pub fn priv_dir() {
  let assert Ok(priv_dir) = application.priv_directory(app_name)
  priv_dir
}
