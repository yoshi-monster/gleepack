import child_process
import child_process/stdio
import filepath
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleepack/config
import gleepack/project
import gleepack/target
import glint.{type Command}
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
    |> snag.context("Could not read project configuration"),
  )

  case project {
    project.GleamProject(..) -> {
      use Nil <- result.try(case project.target {
        Some(project.Javascript) ->
          snag.error(
            config.app_name <> " does not support JavaScript target projects",
          )
        _ -> Ok(Nil)
      })

      let _output =
        output(flags)
        |> result.unwrap(
          project.output |> option.unwrap(filepath.join("build", project.name)),
        )

      let _entry =
        module(flags)
        |> result.unwrap(project.module |> option.unwrap(project.name))

      use _targets <- result.try(case targets(flags) {
        Error(_) | Ok([]) ->
          case project.targets {
            [] ->
              case target.default() {
                Ok(target) -> Ok([target])
                Error(Nil) ->
                  snag.error(
                    "Your platform is currently not supported. Please open an issue!",
                  )
              }
            targets -> Ok(targets)
          }

        Ok(targets) ->
          list.try_map(targets, fn(target) {
            target.from_string(target)
            |> snag.replace_error("Invalid target " <> string.inspect(target))
          })
      })

      use _ <- result.try(run("gleam", in: ".", with: ["deps", "download"]))

      use _compile_deps <- result.try(project.read_compile_dependencies(project))
      use _dependencies <- result.try(project.read_dependencies(project))

      // use entrypoint_source <- result.try(
      //   entrypoint.render(project, entry)
      //   |> snag.map_error(simplifile.describe_error)
      //   |> snag.context("Could not render gleewrap_main.erl"),
      // )

      // use _ <- result.try(
      //   compile.compile_all(compile.Options(
      //     project:,
      //     dependencies: compile_deps,
      //     target: None,
      //     emit_beams: True,
      //     entrypoint: Some(entrypoint_source),
      //   )),
      // )

      // use files <- result.try(files(dependencies))
      // use entrypoint_beam <- result.try(
      //   simplifile.read_bits(filepath.join(
      //     compile.build_dir,
      //     "gleewrap_main.beam",
      //   ))
      //   |> snag.map_error(simplifile.describe_error)
      //   |> snag.context("Could not read compiled gleewrap_main.beam"),
      // )
      // let files = [
      //   #(charlist.from_string("gleewrap_main.beam"), entrypoint_beam),
      //   ..files
      // ]

      // let emu_args = "-escript main gleewrap_main"
      // let emu_args = case project_extra_emu_args {
      //   Some(extra_args) -> emu_args <> " " <> extra_args
      //   None -> emu_args
      // }

      // let zip_options = [
      //   Uncompress([
      //     charlist.from_string(".app"),
      //     charlist.from_string(".dll"),
      //     charlist.from_string(".so"),
      //     charlist.from_string(".dynlib"),
      //   ]),
      // ]

      // let options = [
      //   Shebang,
      //   Comment(charlist.from_string("")),
      //   EmuArgs(charlist.from_string(emu_args)),
      //   Archive(files, zip_options),
      // ]

      // let result = create_escript(charlist.from_string(output), options)

      // use Nil <- result.try(case result == atom.to_dynamic(atom.create("ok")) {
      //   True -> Ok(Nil)
      //   False ->
      //     snag.error(string.inspect(result))
      //     |> snag.context("Error creating escript")
      // })

      // use Nil <- result.try(
      //   simplifile.set_permissions_octal(output, 0o755)
      //   |> snag.map_error(simplifile.describe_error)
      //   |> snag.context("Could not make " <> output <> " executable"),
      // )

      // let size_str = case simplifile.file_info(output) {
      //   Ok(info) -> {
      //     let size =
      //       bytes1024.Bytes(int.to_float(info.size))
      //       |> bytes1024.humanise
      //       |> bytes1024.to_string

      //     " (" <> size <> ")"
      //   }
      //   Error(_) -> ""
      // }

      // io.println(
      //   ansi.pink("   gleewrap")
      //   <> " written to "
      //   <> ansi.bold(output)
      //   <> ansi.dim(size_str),
      // )
      Ok(Nil)
    }

    _ ->
      snag.error(
        "Expected a Gleam project but found a non-Gleam project at current directory",
      )
  }
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
  |> snag.context("Error running " <> command <> " " <> string.join(args, " "))
}
