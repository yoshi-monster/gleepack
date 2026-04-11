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

fn tokens(args: emu_args.EmuArgs) -> List(String) {
  emu_args.render(args)
  |> string.split("\u{0}")
  |> list.filter(fn(s) { !string.is_empty(s) })
}

pub fn render_beam_and_erlang_test() {
  let args = emu_args.parse("+P 65536 -noshell -mode minimal")
  assert tokens(args)
    == [
      "-P", "65536", "--", "-root", "/__gleepack__", "-bindir",
      "/__gleepack__/bin", "-boot", "/__gleepack__/start", "-run",
      "gleepack_main", "main", "-noshell", "-mode", "minimal",
    ]
}

pub fn render_no_beam_flags_test() {
  let args = emu_args.parse("-noshell")
  assert tokens(args)
    == [
      "--", "-root", "/__gleepack__", "-bindir", "/__gleepack__/bin", "-boot",
      "/__gleepack__/start", "-run", "gleepack_main", "main", "-noshell",
    ]
}

pub fn render_no_erlang_flags_test() {
  let args = emu_args.parse("+P 65536")
  assert tokens(args)
    == [
      "-P", "65536", "--", "-root", "/__gleepack__", "-bindir",
      "/__gleepack__/bin", "-boot", "/__gleepack__/start", "-run",
      "gleepack_main", "main",
    ]
}

pub fn render_default_test() {
  let args = emu_args.parse(emu_args.default)
  assert tokens(args)
    == [
      "-L", "-d", "-Bd", "-P", "65536", "-Q", "1024", "-sbtu", "-A0", "--",
      "-root", "/__gleepack__", "-bindir", "/__gleepack__/bin", "-boot",
      "/__gleepack__/start", "-run", "gleepack_main", "main", "-noshell",
      "-noinput", "-mode", "interactive", "-start_epmd", "false", "-dist_listen",
      "false",
    ]
}

pub fn render_trailing_nul_test() {
  // The raw bytes must end with NUL so the C 2-pass parser counts correctly.
  let args = emu_args.parse("+P 65536")
  assert string.ends_with(emu_args.render(args), "\u{0}")
}
