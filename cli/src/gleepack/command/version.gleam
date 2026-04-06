import gleam/io
import gleam_community/ansi
import gleepack/config
import glint.{type Command}
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help("Print the version of gleepack.")
  use _, _, _ <- glint.command()

  io.println(ansi.pink(config.app_name) <> " v" <> version(config.app_name))

  Ok(Nil)
}

@external(erlang, "gleepack_ffi", "version")
fn version(application: String) -> String
