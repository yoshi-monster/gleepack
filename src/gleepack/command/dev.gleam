import gleam/option
import gleepack/command/run
import glint.{type Command}
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Build your Gleam project and run its development entry point directly using
the native toolchain. Invokes the `main` function of the `<project_name>_dev`
module.
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
    module_for: fn(name, _) { name <> "_dev" },
    target: option.from_result(target(flags)),
    args: args,
  )
}
