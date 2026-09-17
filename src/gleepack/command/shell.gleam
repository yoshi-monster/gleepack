import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleepack/command/build
import gleepack/command/run
import gleepack/config
import gleepack/io
import gleepack/mode
import gleepack/project
import gleepack/target
import glint.{type Command}
import snag.{type Snag}

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

      io.with_temporary_file(
        directory: config.build_dir,
        prefix: project.name <> "-",
        run: build_and_shell(_, project, available, native_target),
      )
      |> result.flatten
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

  io.from_file(tmp_path)
  |> io.env("GLEEPACK_RAW_ARGS", "1")
  |> io.arg("--")
  |> io.arg2("-root", "/__gleepack__")
  |> io.arg2("-bindir", "/__gleepack__/bin")
  |> io.arg2("-boot", "/__gleepack__/start")
  |> io.arg2("-start_epmd", "false")
  |> io.arg2("-dist_listen", "false")
  |> io.run
}
