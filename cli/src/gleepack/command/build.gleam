import child_process
import child_process/stdio
import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import gleepack/config
import gleepack/dependency
import gleepack/project
import gleepack/release_compiler
import gleepack/target
import glint.{type Command}
import simplifile
import snag.{type Snag}

pub fn command() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Build your Gleam project and produce a standalone executable ready to be
distributed. The resulting binary is optimised for building CLIs, TUIs, and
dev tools. Some optimisations such as dead-code elimination may also be
performed.
  ",
  )

  use output <- glint.flag(
    glint.string_flag("output")
    |> glint.flag_help("
Configure where the built executable file will be written to: by default this
is `./build/$project_name` within the project root.

This option can also be provided in your `gleam.toml` configuration under the
key `tools." <> config.app_name <> ".output`.
      "),
  )

  use module <- glint.flag(
    glint.string_flag("module")
    |> glint.flag_help("
Configure which modules main function will be called: By default this is a
module called $project_name, matching the one `gleam run` would run by default.

This option can also be provided in your `gleam.toml` configuration under the
key `tools." <> config.app_name <> ".module`.
      "),
  )

  use targets <- glint.flag(
    glint.strings_flag("target")
    |> glint.flag_help("
Configure which target to build for. A target identifier is constructed from
segments, and looks like `arch-os-runtime-version-extra`. For example, to build
your application for x86-64 Linux, use `amd64-linux-otp-24.4.1-static`.

You can provide this flag multiple times to build your app for multiple targets.
To list all available targets, use `gleam run -m gleepack list-targets`.

This option can also be provided in your `gleam.toml` configuration under the
key `tools." <> config.app_name <> ".targets`.
      "),
  )

  use _, _entries, flags <- glint.command

  use project <- result.try(
    project.read(".")
    |> snag.context("Reading project configuration"),
  )

  use Nil <- result.try(case project {
    project.Gleam(target: Some(project.Javascript), ..) ->
      snag.error(config.app_name <> " does not support JavaScript target projects")
    project.Gleam(..) -> Ok(Nil)
    _ ->
      snag.error(
        "Expected a Gleam project but found a non-Gleam project at current directory",
      )
  })

  let assert project.Gleam(..) = project

  let out =
    output(flags)
    |> result.unwrap(
      project.output |> option.unwrap(filepath.join("build", project.name)),
    )

  let entry =
    module(flags)
    |> result.unwrap(project.module |> option.unwrap(project.name))

  use requested_targets <- result.try(case targets(flags) {
    Error(_) | Ok([]) ->
      case project.targets {
        [] ->
          case target.default() {
            Ok(t) -> Ok([t])
            Error(Nil) ->
              snag.error(
                "Your platform is currently not supported. Please open an issue!",
              )
          }
        ts -> Ok(ts)
      }
    Ok(slugs) ->
      list.try_map(slugs, fn(s) {
        target.from_string(s)
        |> snag.replace_error("Invalid target " <> string.inspect(s))
      })
  })

  use _ <- result.try(run("gleam", in: ".", with: ["deps", "download"]))

  use manifest <- result.try(
    project.manifest() |> snag.context("Reading project manifest"),
  )

  use compile_deps <- result.try(
    dependency.all(project, manifest)
    |> snag.context("Resolving all dependencies"),
  )
  use dependencies <- result.try(
    dependency.production(project, manifest)
    |> snag.context("Resolving production dependencies"),
  )

  list.try_each(requested_targets, fn(runtime_target) {
    build_for_target(
      project:,
      entry:,
      out:,
      compile_deps:,
      dependencies:,
      runtime_target:,
      multi_target: list.length(requested_targets) > 1,
    )
  })
}

fn build_for_target(
  project project: project.Project,
  entry entry: String,
  out out: String,
  compile_deps compile_deps: List(project.Project),
  dependencies dependencies: List(project.Project),
  runtime_target runtime_target: target.Target,
  multi_target multi_target: Bool,
) -> Result(Nil, Snag) {
  use runtime_installed <- result.try(
    target.install(runtime_target)
    |> snag.context("Installing runtime " <> target.slug(runtime_target)),
  )

  use compile_target <- result.try(
    target.matching_native(matching: runtime_target)
    |> snag.replace_error(
      "No native toolchain available for "
      <> target.slug(runtime_target)
      <> ". Cannot compile.",
    ),
  )

  use compile_installed <- result.try(
    target.install(compile_target)
    |> snag.context("Installing compile toolchain " <> target.slug(compile_target)),
  )

  use zip <- result.try(
    release_compiler.build(
      project:,
      module: entry,
      dependencies:,
      compile_dependencies: compile_deps,
      target: compile_installed,
    )
    |> snag.context("Building release for " <> target.slug(runtime_target)),
  )

  use runtime_binary <- result.try(
    simplifile.read_bits(runtime_installed.runtime_binary)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Reading runtime binary"),
  )

  let output_path = case multi_target {
    True -> out <> "-" <> target.slug(runtime_target)
    False -> out
  }

  // Preserve the runtime binary's extension (e.g. .exe on Windows).
  let output_path = case filepath.extension(runtime_installed.runtime_binary) {
    Ok(ext) -> output_path <> "." <> ext
    Error(Nil) -> output_path
  }

  use Nil <- result.try(
    simplifile.create_directory_all(filepath.directory_name(output_path))
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Creating output directory"),
  )

  use Nil <- result.try(
    simplifile.write_bits(output_path, <<runtime_binary:bits, zip:bits>>)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Writing " <> output_path),
  )

  use Nil <- result.try(
    simplifile.set_permissions_octal(output_path, 0o755)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Setting executable permissions on " <> output_path),
  )

  io.println(ansi.pink("      Built ") <> output_path)
  Ok(Nil)
}

fn run(
  command: String,
  in directory: String,
  with args: List(String),
) -> Result(Nil, Snag) {
  case
    child_process.from_name(command)
    |> child_process.cwd(directory)
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
  |> snag.context("Running " <> command <> " " <> string.join(args, " "))
}
