import gleam_community/ansi
import glint.{type Command}
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "Build your application into a standalone executable.",
  )

  use _output <- glint.flag(
    glint.string_flag("output")
    |> glint.flag_help("Path to write the output escript"),
  )

  use _module <- glint.flag(
    glint.string_flag("module")
    |> glint.flag_help(
      "Entry module (e.g. lustre/dev). Defaults to the project name.",
    ),
  )

  use _target <- glint.flag(
    glint.strings_flag("target")
    |> glint.flag_help(
      "A target identifier string, for example "
      <> ansi.pink("linux-otp-28.4.1-static"),
    ),
  )

  use _, _args, _flags <- glint.command

  snag.error("build is not implemented yet.")
}
