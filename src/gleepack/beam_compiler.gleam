import child_process/line_buffer.{type LineBuffer}
import directories
import filepath
import gleam/erlang/process.{type Selector}
import gleam/list
import gleam/result
import gleepack/config
import gleepack/eterm/decode
import gleepack/eterm/encode
import gleepack/io.{type Process}
import gleepack/target.{type InstalledTarget}
import snag.{type Snag}

pub opaque type BeamCompiler {
  Compiler(process: Process, line_buffer: LineBuffer)
}

pub opaque type Msg {
  Data(BitArray)
  Exit(Int)
}

pub type Update {
  Running(compiler: BeamCompiler, compiled: List(String), failed: List(String))
  Exited(code: Int)
}

/// Start a beam compiler subprocess, first extracting the compiler script
/// from priv to build_dir so external BEAM processes can access it by path.
pub fn start(target: InstalledTarget) -> Result(BeamCompiler, Snag) {
  let script_dest = filepath.join(config.build_dir, "gleepack_compiler.erl")
  use _ <- result.try(extract_compiler_script(script_dest))
  use process <- result.try(
    io.from_file(target.runtime_binary)
    |> io.args(["-L", "-d", "-Bd", "-sbtu", "-A0"])
    |> io.arg2("-P", "65536")
    |> io.arg2("-Q", "1024")
    |> io.arg("--")
    |> io.arg2("-root", target.otp_directory)
    |> io.arg2("-bindir", target.otp_directory)
    |> io.arg2("-home", directories.home_dir() |> result.unwrap("/"))
    |> io.arg2("-boot", filepath.join(target.otp_directory, "start"))
    |> io.arg2("-mode", "minimal")
    |> io.arg("-noshell")
    |> io.args(["-run", "escript", "start"])
    |> io.arg("-extra")
    |> io.arg(script_dest)
    |> io.arg(config.build_dir)
    |> io.spawn(output: io.Capture(False)),
  )

  Ok(Compiler(process:, line_buffer: line_buffer.new()))
}

fn extract_compiler_script(dest: String) -> Result(Nil, Snag) {
  let src = filepath.join(config.priv_dir(), "gleepack_compiler.erl")
  use content <- result.try(io.read_bits(src))
  io.write_bits(dest, content)
}

pub fn select(
  selector: Selector(Msg),
  compiler: BeamCompiler,
) -> Selector(Msg) {
  io.select_process(selector, compiler.process, Data, Exit)
}

/// Write a source file to the compiler queue.
///
/// The compiler reads lines formatted as `{<<"ebin">>,<<"src">>}.` and
/// compiles them concurrently, outputting one response line per file.
pub fn compile(
  compiler: BeamCompiler,
  out: String,
  module: String,
) -> Result(Nil, Snag) {
  io.write_process(
    compiler.process,
    encode.tuple([encode.string(out), encode.string(module)])
      |> encode.to_string,
  )
}

pub fn stop(compiler: BeamCompiler) -> Nil {
  io.close_process(compiler.process)
}

pub fn handle_msg(compiler: BeamCompiler, msg: Msg) -> Update {
  case msg {
    Data(data) -> {
      let #(lines, line_buffer) = compiler.line_buffer |> line_buffer.feed(data)
      let #(compiled, failed) = handle_lines(lines, [], [])
      Running(compiler: Compiler(..compiler, line_buffer:), compiled:, failed:)
    }
    Exit(code) -> Exited(code)
  }
}

fn handle_lines(
  lines: List(String),
  compiled: List(String),
  failed: List(String),
) -> #(List(String), List(String)) {
  case lines {
    [] -> #(compiled, failed)
    ["gleepack-compile-ok " <> eterm, ..rest] ->
      case parse_compile_result(eterm) {
        Ok(#(_, modules)) ->
          handle_lines(rest, list.append(compiled, modules), failed)
        Error(Nil) -> handle_lines(rest, compiled, failed)
      }
    ["gleepack-compile-error " <> eterm, ..rest] ->
      case parse_compile_result(eterm) {
        Ok(#(file, _)) -> handle_lines(rest, compiled, [file, ..failed])
        Error(Nil) -> handle_lines(rest, compiled, failed)
      }
    [line, ..rest] -> {
      io.print(line)
      handle_lines(rest, compiled, failed)
    }
  }
}

fn parse_compile_result(eterm: String) -> Result(#(String, List(String)), Nil) {
  let decoder = {
    use file <- decode.element(0, decode.string())
    use modules <- decode.element(1, decode.list(decode.atom()))
    decode.success(#(file, modules))
  }

  decode.parse(eterm, decoder) |> result.replace_error(Nil)
}
