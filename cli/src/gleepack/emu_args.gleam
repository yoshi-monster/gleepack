/// Parses and renders VM arguments for the erl_args file bundled in the ZIP.
///
/// Follows the erlexec convention: tokens starting with `+` are BEAM emulator
/// flags (placed before `--`, leading `+` replaced with `-`), tokens starting
/// with `-` are Erlang runtime flags (placed after `--`).  Bare tokens with no
/// leading `+`/`-` are arguments to the preceding flag and go into the same
/// section.
import gleam/list
import gleam/string

/// VM arguments split into BEAM emulator flags (go before `--`) and Erlang
/// runtime flags (go after `--`).
pub type EmuArgs {
  EmuArgs(beam_flags: List(String), erlang_flags: List(String))
}

/// Default value for the `extra_emu_args` config key.
pub const default = "+L +d +Bd +P 65536 +Q 1024 +sbtu +A0 -noshell -noinput -mode minimal"

type Section {
  Beam
  Erlang
}

/// Parse an `extra_emu_args` string into BEAM and Erlang flag lists.
pub fn parse(input: String) -> EmuArgs {
  let tokens =
    string.split(input, " ")
    |> list.filter(fn(s) { !string.is_empty(s) })
  do_parse(tokens, [], [], Beam)
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
pub fn render(args: EmuArgs, release_version: String) -> String {
  let header = case args.beam_flags {
    [] -> ["--"]
    flags -> list.append(flags, ["--"])
  }
  let required = [
    "-root", "/__gleepack__",
    "-bindir", "/__gleepack__/bin",
    "-boot", "/__gleepack__/releases/" <> release_version <> "/start",
    "-kernel", "inetrc", "/__gleepack__/erl_inetrc",
  ]
  let all = list.flatten([header, required, args.erlang_flags])
  string.join(all, "\u{0}") <> "\u{0}"
}
