import child_process
import child_process/stdio
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleepack/command/build
import gleepack/command/run
import gleepack/config
import gleepack/mode
import gleepack/project
import gleepack/target
import glint.{type Command}
import simplifile
import snag.{type Snag}
import temporary

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Build your Gleam project and open an interactive Erlang shell with all
application code loaded. Always targets the current platform.
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

  use _, _, flags <- glint.command

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
      use native_target <- result.try(case target(flags) {
        Error(_) ->
          case target.default(available) {
            Ok(t) -> Ok(t)
            Error(Nil) ->
              snag.error(
                "Your platform is currently not supported. Please open an issue!",
              )
          }
        Ok(slug) -> {
          use t <- result.try(
            target.from_string(available, slug)
            |> snag.replace_error("Invalid target " <> string.inspect(slug)),
          )
          case target.supported(t) {
            True -> Ok(t)
            False ->
              snag.error(
                "Target "
                <> slug
                <> " is not supported on this platform and cannot be run directly",
              )
          }
        }
      })

      run.clean_leftover_executables(project.name)

      case
        temporary.create(
          temporary.file()
            |> temporary.in_directory(config.build_dir)
            |> temporary.with_prefix(project.name <> "-"),
          run: build_and_shell(_, project, available, native_target),
        )
      {
        Ok(result) -> result
        Error(file_error) ->
          snag.error(simplifile.describe_error(file_error))
          |> snag.context("Creating temporary file")
      }
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

fn build_and_shell(tmp_path, project, available, target) {
  use pairs <- result.try({
    build.build(project, available, [#(target, tmp_path)], mode.Shell)
  })

  let assert [#(_, tmp_path)] = pairs

  case
    child_process.from_file(tmp_path)
    |> child_process.env("GLEEPACK_RAW_ARGS", "1")
    |> child_process.arg("--")
    |> child_process.arg2("-root", "/__gleepack__")
    |> child_process.arg2("-bindir", "/__gleepack__/bin")
    |> child_process.arg2("-boot", "/__gleepack__/start")
    |> child_process.arg2("-start_epmd", "false")
    |> child_process.arg2("-dist_listen", "false")
    |> child_process.run(stdio.inherit())
  {
    Ok(child_process.Output(status_code: 0, output: _)) -> Ok(Nil)
    Ok(child_process.Output(status_code:, output: _)) ->
      snag.error(
        "Command failed with status code " <> int.to_string(status_code),
      )
    Error(error) -> snag.error(child_process.describe_start_error(error))
  }
  |> snag.context("Running Erlang shell")
}
