import child_process
import child_process/stdio
import filepath
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleepack/command/build
import gleepack/config
import gleepack/project
import gleepack/target
import glint.{type Command}
import simplifile
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Build your Gleam project and run it directly using the native toolchain,
without producing a distributable executable. Always targets the current
platform.
  ",
  )

  use module <- glint.flag(
    glint.string_flag("module")
    |> glint.flag_help("
Configure which module's main function will be called: By default this is a
module called $project_name, matching the one `gleam run` would run by default.

This option can also be provided in your `gleam.toml` configuration under the
key `tools." <> config.app_name <> ".module`.
      "),
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

  use available <- result.try(
    target.available() |> snag.context("Loading available targets"),
  )

  use project <- result.try(
    project.read(".", available: available)
    |> snag.context("Reading project configuration"),
  )

  case project {
    project.Gleam(target: None, ..)
    | project.Gleam(target: Some(project.Erlang), ..) -> {
      let module =
        module(flags)
        |> result.unwrap(project.module |> option.unwrap(project.name))

      use target <- result.try(case target(flags) {
        Error(_) ->
          case target.default(available) {
            Ok(t) -> Ok(t)
            Error(Nil) ->
              snag.error(
                "Your platform is currently not supported. Please open an issue!",
              )
          }
        Ok(slug) -> {
          use target <- result.try(
            target.from_string(available, slug)
            |> snag.replace_error("Invalid target " <> string.inspect(slug)),
          )
          case target.supported(target) {
            True -> Ok(target)
            False ->
              snag.error(
                "Target "
                <> slug
                <> " is not supported on this platform and cannot be run directly",
              )
          }
        }
      })

      let tmp_base = filepath.join(config.build_dir, "gleepack-run-tmp")

      use pairs <- result.try({
        build.build(project, available, [#(target, tmp_base)], module)
      })

      let assert [#(_, tmp_path)] = pairs

      let status =
        case
          child_process.from_file(tmp_path)
          |> child_process.args(args)
          |> child_process.run(stdio.inherit())
        {
          Ok(child_process.Output(status_code: 0, output: _)) -> Ok(Nil)
          Ok(child_process.Output(status_code:, output: _)) ->
            snag.error(
              "Command failed with status code " <> int.to_string(status_code),
            )
          Error(error) -> snag.error(child_process.describe_start_error(error))
        }
        |> snag.context("Running " <> target.slug(target))

      let _ = simplifile.delete(tmp_path)

      status
    }

    project.Gleam(target: Some(project.Javascript), ..) ->
      snag.error(
        config.app_name <> " does not support JavaScript target projects",
      )

    _ ->
      snag.error(
        "Expected a Gleam project but found a non-Gleam project at current directory",
      )
  }
}
