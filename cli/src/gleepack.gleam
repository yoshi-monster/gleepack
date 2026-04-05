import argv.{Argv}
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam_community/ansi
import gleepack/command/build
import gleepack/command/clean
import gleepack/command/version
import gleepack/config
import glint
import snag

pub fn main() -> Nil {
  let cli =
    glint.new()
    |> glint.as_module
    |> glint.with_name(config.app_name)
    |> glint.pretty_help(glint.default_pretty_help())
    |> glint.add(at: ["build"], do: build.command())
    |> glint.add(at: ["clean"], do: clean.command())
    |> glint.add(at: ["version"], do: version.command())

  let Argv(arguments:, ..) = argv.load()

  let result = case glint.execute(cli, arguments) {
    Ok(glint.Help(help)) -> Ok(io.println(help))
    Ok(glint.Out(Ok(Nil))) -> Ok(Nil)
    Ok(glint.Out(Error(reason))) ->
      Error(io.println_error("\n" <> format_error(reason)))
    Error(message) -> Error(io.println_error(message))
  }

  let exit_code = case result {
    Ok(Nil) -> 0
    Error(Nil) -> 1
  }

  halt(exit_code)
}

fn format_error(err: snag.Snag) -> String {
  let header = ansi.bold(ansi.red("error")) <> ": " <> err.issue
  case err.cause {
    [] -> header
    cause -> {
      let lines =
        list.index_map(cause, fn(c, i) {
          "  " <> ansi.dim(int.to_string(i) <> ":") <> " " <> c
        })
      header
      <> "\n\n"
      <> ansi.bold("cause:")
      <> "\n"
      <> string.join(lines, "\n")
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(status_code: Int) -> Nil
