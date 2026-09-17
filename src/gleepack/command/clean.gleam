import gleepack/config
import gleepack/io
import glint.{type Command}
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Remove the gleepack build directory, discarding any previously compiled
artefacts. This forces a full recompile on the next `gleepack build` run.

This is usually not necessary - gleepack always recompiles the entire project.
    ",
  )
  use _, _, _ <- glint.command

  io.delete(config.build_dir)
  |> snag.context("Could not remove " <> config.build_dir)
}
