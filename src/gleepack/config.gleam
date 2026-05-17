import directories
import envoy
import filepath
import gleam/erlang/application

pub const app_name = "gleepack"

pub const build_dir = "build/" <> app_name

pub fn cache_dir() {
  case envoy.get("GLEEPACK_CACHE_DIR") {
    Ok(dir) -> dir
    Error(_) -> {
      let assert Ok(base) = directories.data_local_dir()
      filepath.join(base, app_name)
    }
  }
}

pub fn priv_dir() {
  let assert Ok(priv_dir) = application.priv_directory(app_name)
  priv_dir
}
