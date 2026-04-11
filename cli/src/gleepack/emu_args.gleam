//// Parses and renders VM arguments for the erl_args file bundled in the ZIP.
////
//// Follows the erlexec convention: tokens starting with `+` are BEAM emulator
//// flags (placed before `--`, leading `+` replaced with `-`), tokens starting
//// with `-` are Erlang runtime flags (placed after `--`).  Bare tokens with no
//// leading `+`/`-` are arguments to the preceding flag and go into the same
//// section.

import gleam/list
import gleam/string

/// VM arguments split into BEAM emulator flags (go before `--`) and Erlang
/// runtime flags (go after `--`).
pub type EmuArgs {
  EmuArgs(beam_flags: List(String), erlang_flags: List(String))
}

/// Default value for the `extra_emu_args` config key.
pub const default = "+L +d +Bd +P 65536 +Q 1024 +sbtu +A0 -noshell -noinput -mode interactive -start_epmd false -dist_listen false"

type Section {
  Beam
  Erlang
}

/// Parse an `extra_emu_args` string into BEAM and Erlang flag lists.
pub fn parse(input: String) -> EmuArgs {
  do_parse(string.split(input, " "), [], [], Beam)
}

fn do_parse(
  tokens: List(String),
  beam_acc: List(String),
  erlang_acc: List(String),
  section: Section,
) -> EmuArgs {
  case tokens {
    [] ->
      EmuArgs(
        beam_flags: list.reverse(beam_acc),
        erlang_flags: list.reverse(erlang_acc),
      )
    ["", ..rest] -> do_parse(rest, beam_acc, erlang_acc, section)
    ["+" <> flag, ..rest] ->
      do_parse(rest, ["-" <> flag, ..beam_acc], erlang_acc, Beam)
    ["-" <> _ as flag, ..rest] ->
      do_parse(rest, beam_acc, [flag, ..erlang_acc], Erlang)
    [token, ..rest] ->
      case section {
        Beam -> do_parse(rest, [token, ..beam_acc], erlang_acc, Beam)
        Erlang -> do_parse(rest, beam_acc, [token, ..erlang_acc], Erlang)
      }
  }
}

/// Render EmuArgs into the content of the `erl_args` file.
///
/// Tokens are NUL-separated with a trailing NUL so the C runtime can parse
/// them with two pointer passes and zero copies. Structural flags (-root,
/// -bindir, -boot, -kernel, -extra) are always included and are not
/// user-configurable.
pub fn render(args: EmuArgs) -> String {
  let required = [
    "-root",
    "/__gleepack__",
    "-bindir",
    "/__gleepack__/bin",
    "-boot",
    "/__gleepack__/start",
    "-run",
    "gleepack_main",
    "main",
  ]

  let all = list.flatten([args.beam_flags, ["--"], required, args.erlang_flags])

  string.join(all, "\u{0}") <> "\u{0}"
}
