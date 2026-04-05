import gleepack/config
import glint.{type Command}
import simplifile
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "Remove the " <> config.app_name <> " build directory",
  )
  use _, _, _ <- glint.command

  case simplifile.delete(config.build_dir) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(e) ->
      snag.error(simplifile.describe_error(e))
      |> snag.context("Could not remove " <> config.build_dir)
  }
}
