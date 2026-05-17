import child_process
import child_process/stdio
import filepath
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleepack/command/build
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

  let module_for = fn(name, configured) {
    module(flags)
    |> result.unwrap(configured |> option.unwrap(name))
  }

  run(module_for, option.from_result(target(flags)), args)
}

/// Build the project in `Debug` mode and execute the resulting binary.
///
/// The module to invoke is computed from the project's name and its
/// `tools.gleepack.module` config (if any) via `module_for`, so callers like
/// `gleepack test` can hard-code conventions such as `<project>_test` without
/// re-implementing the rest of the pipeline.
pub fn run(
  module_for module_for: fn(String, Option(String)) -> String,
  target target_slug: Option(String),
  args args: List(String),
) -> Result(Nil, Snag) {
  use available <- result.try(
    target.available() |> snag.context("Loading available targets"),
  )

  use project <- result.try(
    project.read(".", available: available)
    |> snag.context("Reading project configuration"),
  )

  // We intentionally don't reject Gleam projects with `target = "javascript"`
  // here: the entrypoint may live in a dependency whose Erlang support is
  // independent of the main project's target. If the chosen module can't
  // compile to Erlang, the build itself will surface the error.
  case project {
    project.Gleam(name:, module: configured, ..) -> {
      let module = module_for(name, configured)

      use native_target <- result.try(resolve_native_target(
        target_slug,
        available,
      ))

      use _ <- result.try(
        simplifile.create_directory_all(config.build_dir)
        |> snag.map_error(simplifile.describe_error)
        |> snag.context("Creating " <> config.build_dir),
      )

      clean_leftover_executables(project.name)

      case
        temporary.create(
          temporary.file()
            |> temporary.in_directory(config.build_dir)
            |> temporary.with_prefix(project.name <> "-"),
          run: build_and_run(_, project, available, native_target, module, args),
        )
      {
        Ok(result) -> result
        Error(file_error) ->
          snag.error(simplifile.describe_error(file_error))
          |> snag.context("Creating temporary file")
      }
    }

    _ ->
      snag.error(
        "Expected a Gleam project but found a non-Gleam project at current directory",
      )
  }
}

/// Delete leftover build artefacts in `build/gleepack/` matching the temp
/// pattern used for one-shot runs (`<project>-<hash>`). These would normally
/// be removed by `temporary.create`'s cleanup, but a hard interrupt (kill -9,
/// crash, etc.) on a prior run can leave them behind.
pub fn clean_leftover_executables(project_name: String) -> Nil {
  let prefix = project_name <> "-"

  use entry <- list.each(
    simplifile.read_directory(config.build_dir)
    |> result.unwrap([]),
  )

  use <- bool.guard(!string.starts_with(entry, prefix), Nil)

  let _ = simplifile.delete(filepath.join(config.build_dir, entry))
  Nil
}

fn resolve_native_target(
  slug: Option(String),
  available: List(target.Target),
) -> Result(target.Target, Snag) {
  case slug {
    None ->
      case target.default(available) {
        Ok(t) -> Ok(t)
        Error(Nil) ->
          snag.error(
            "Your platform is currently not supported. Please open an issue!",
          )
      }
    Some(slug) -> {
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
  }
}

fn build_and_run(tmp_path, project, available, target, module, args) {
  use pairs <- result.try({
    build.build(project, available, [#(target, tmp_path)], mode.Debug(module:))
  })

  let assert [#(_, tmp_path)] = pairs

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
  |> snag.context("Running " <> tmp_path)
}
