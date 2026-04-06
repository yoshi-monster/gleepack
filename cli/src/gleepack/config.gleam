import directories
import filepath

pub const app_name = "gleepack"

pub const build_dir = "build/" <> app_name

pub fn cache_dir() {
  let assert Ok(cache_dir) = directories.data_local_dir()
  filepath.join(cache_dir, app_name)
}
