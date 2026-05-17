import gleam/option
import gleepack/command/run
import glint.{type Command}
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Build your Gleam project and start the Lustre dev tools by invoking the
`main` function of the `lustre/dev` module. The project must depend on
`lustre_dev_tools` for this command to succeed.
  ",
  )

  use target <- glint.flag(
    glint.string_flag("target")
    |> glint.flag_help(
      "
Configure which target to run. Must be a native target for the current platform.
Defaults to the highest available OTP version for the current platform.
      ",
    ),
  )

  use _, args, flags <- glint.command

  run.run(
    module_for: fn(_, _) { "lustre/dev" },
    target: option.from_result(target(flags)),
    args: args,
  )
}
