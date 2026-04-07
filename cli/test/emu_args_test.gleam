/// Tests for erl_args file generation.
import gleam/list
import gleam/string
import gleepack/emu_args

pub fn parse_beam_flags_test() {
  let args = emu_args.parse("+P 65536 +sbtu")
  assert args.beam_flags == ["-P", "65536", "-sbtu"]
  assert args.erlang_flags == []
}

pub fn parse_erlang_flags_test() {
  let args = emu_args.parse("-noshell -mode minimal")
  assert args.beam_flags == []
  assert args.erlang_flags == ["-noshell", "-mode", "minimal"]
}

pub fn parse_mixed_test() {
  // +flags become BEAM flags, -flags become Erlang flags, bare tokens follow
  // the section of the preceding flag token.
  let args = emu_args.parse("+P 65536 +sbtu -noshell +A0 -mode minimal")
  assert args.beam_flags == ["-P", "65536", "-sbtu", "-A0"]
  assert args.erlang_flags == ["-noshell", "-mode", "minimal"]
}

pub fn parse_ignores_extra_spaces_test() {
  let args = emu_args.parse("+P  65536")
  assert args.beam_flags == ["-P", "65536"]
}

pub fn parse_empty_test() {
  let args = emu_args.parse("")
  assert args.beam_flags == []
  assert args.erlang_flags == []
}

fn tokens(args: emu_args.EmuArgs, version: String) -> List(String) {
  emu_args.render(args, version)
  |> string.split("\u{0}")
  |> list.filter(fn(s) { !string.is_empty(s) })
}

pub fn render_beam_and_erlang_test() {
  let args = emu_args.parse("+P 65536 -noshell -mode minimal")
  assert tokens(args, "1.0.0") == [
    "-P", "65536", "--",
    "-root", "/__gleepack__",
    "-bindir", "/__gleepack__/bin",
    "-boot", "/__gleepack__/releases/1.0.0/start",
    "-kernel", "inetrc", "/__gleepack__/erl_inetrc",
    "-noshell", "-mode", "minimal",
  ]
}

pub fn render_no_beam_flags_test() {
  let args = emu_args.parse("-noshell")
  assert tokens(args, "1.0.0") == [
    "--",
    "-root", "/__gleepack__",
    "-bindir", "/__gleepack__/bin",
    "-boot", "/__gleepack__/releases/1.0.0/start",
    "-kernel", "inetrc", "/__gleepack__/erl_inetrc",
    "-noshell",
  ]
}

pub fn render_no_erlang_flags_test() {
  let args = emu_args.parse("+P 65536")
  assert tokens(args, "1.0.0") == [
    "-P", "65536", "--",
    "-root", "/__gleepack__",
    "-bindir", "/__gleepack__/bin",
    "-boot", "/__gleepack__/releases/1.0.0/start",
    "-kernel", "inetrc", "/__gleepack__/erl_inetrc",
  ]
}

pub fn render_default_test() {
  let args = emu_args.parse(emu_args.default)
  assert tokens(args, "1.0.0") == [
    "-L", "-d", "-Bd", "-P", "65536", "-Q", "1024", "-sbtu", "-A0", "--",
    "-root", "/__gleepack__",
    "-bindir", "/__gleepack__/bin",
    "-boot", "/__gleepack__/releases/1.0.0/start",
    "-kernel", "inetrc", "/__gleepack__/erl_inetrc",
    "-noshell", "-noinput", "-mode", "minimal",
  ]
}

pub fn render_trailing_nul_test() {
  // The raw bytes must end with NUL so the C 2-pass parser counts correctly.
  let args = emu_args.parse("+P 65536")
  assert string.ends_with(emu_args.render(args, "1.0.0"), "\u{0}")
}
