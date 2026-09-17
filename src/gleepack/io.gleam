//// Primitive input and output operations used by gleepack.

import argv.{Argv}
import child_process
import child_process/stdio
import filepath
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Selector}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleepack/zip
import input
import simplifile
import snag.{type Snag}
import temporary

// -- Process types -----------------------------------------------------------

type Executable {
  Named(String)
  File(String)
}

/// A child-process invocation assembled before it is run.
pub opaque type Command {
  Command(
    executable: Executable,
    reverse_arguments: List(String),
    environment: Dict(String, String),
    working_directory: Option(String),
  )
}

/// How a spawned process's standard output and error are handled.
pub type ProcessOutput {
  Inherit
  Ignore
  Capture(capture_stderr: Bool)
}

/// A running child process together with its human-readable command.
pub opaque type Process {
  Process(process: child_process.Process, command: String)
}

// -- Terminal ----------------------------------------------------------------

/// Print a line to standard output.
pub fn println(message: String) -> Nil {
  io.println(message)
}

/// Print a line to standard error.
pub fn println_error(message: String) -> Nil {
  io.println_error(message)
}

/// Print to standard output without adding a newline.
pub fn print(message: String) -> Nil {
  io.print(message)
}

/// Return the command-line arguments passed to gleepack.
pub fn arguments() -> List(String) {
  let Argv(arguments:, ..) = argv.load()
  arguments
}

/// Prompt for and read one line of input.
pub fn prompt(message: String) -> Result(String, Nil) {
  input.input(prompt: message)
}

// -- Child processes ---------------------------------------------------------

/// Start building a command whose executable is resolved through `PATH`.
pub fn from_name(name: String) -> Command {
  new_command(Named(name))
}

/// Start building a command addressed by file path.
pub fn from_file(path: String) -> Command {
  new_command(File(path))
}

/// Append one command-line argument.
pub fn arg(command: Command, argument: String) -> Command {
  Command(..command, reverse_arguments: [argument, ..command.reverse_arguments])
}

/// Append two command-line arguments.
pub fn arg2(command: Command, first: String, second: String) -> Command {
  Command(..command, reverse_arguments: [
    second,
    first,
    ..command.reverse_arguments
  ])
}

/// Append command-line arguments.
pub fn args(command: Command, arguments: List(String)) -> Command {
  list.fold(arguments, command, arg)
}

/// Append one environment variable.
pub fn env(command: Command, name: String, value: String) -> Command {
  Command(..command, environment: dict.insert(command.environment, name, value))
}

/// Set the command's working directory.
pub fn cwd(command: Command, directory: String) -> Command {
  Command(..command, working_directory: Some(directory))
}

/// Run a command to completion, reporting the executable and arguments on error.
pub fn run(command: Command) -> Result(Nil, Snag) {
  let #(builder, description) = prepare_command(command)
  case child_process.run(builder, stdio.inherit()) {
    Ok(child_process.Output(status_code: 0, output: _)) -> Ok(Nil)
    Ok(child_process.Output(status_code:, output: _)) ->
      snag.error("Exited with status code " <> int.to_string(status_code))
    Error(error) -> snag.error(child_process.describe_start_error(error))
  }
  |> snag.context("Running " <> description)
}

/// Start a command, retaining its description for later process errors.
pub fn spawn(
  command: Command,
  output output: ProcessOutput,
) -> Result(Process, Snag) {
  let #(builder, description) = prepare_command(command)
  builder
  |> child_process.spawn_raw(process_output(output))
  |> snag.map_error(child_process.describe_start_error)
  |> snag.context("Starting " <> description)
  |> result.map(fn(process) { Process(process:, command: description) })
}

/// Add a child process's data and exit events to a selector.
pub fn select_process(
  selector: Selector(message),
  process: Process,
  on_data: fn(BitArray) -> message,
  on_exit: fn(Int) -> message,
) -> Selector(message) {
  stdio.select(selector, process.process, on_data, on_exit)
}

/// Write to a child process, reporting the command on error.
pub fn write_process(process: Process, data: String) -> Result(Nil, Snag) {
  child_process.write(process.process, data)
  |> snag.map_error(child_process.describe_write_error)
  |> snag.context("Writing to " <> process.command)
}

/// Close a child process's input stream.
pub fn close_process(process: Process) -> Nil {
  child_process.close(process.process)
}

fn new_command(executable: Executable) -> Command {
  Command(
    executable:,
    reverse_arguments: [],
    environment: dict.new(),
    working_directory: None,
  )
}

fn prepare_command(command: Command) -> #(child_process.Builder, String) {
  let arguments = list.reverse(command.reverse_arguments)
  let builder = case command.executable {
    Named(name) -> child_process.from_name(name)
    File(path) -> child_process.from_file(path)
  }
  let builder =
    builder
    |> child_process.args(arguments)
    |> child_process.envs(dict.to_list(command.environment))
  let builder = case command.working_directory {
    Some(directory) -> child_process.cwd(builder, directory)
    None -> builder
  }
  let executable = case command.executable {
    Named(name) | File(name) -> name
  }
  let invocation = string.join([executable, ..arguments], " ")
  let description = case command.working_directory {
    Some(directory) -> invocation <> " in " <> directory
    None -> invocation
  }
  #(builder, description)
}

fn process_output(output: ProcessOutput) -> stdio.Mode {
  case output {
    Inherit -> stdio.inherit()
    Ignore -> stdio.null()
    Capture(capture_stderr:) -> stdio.capture(capture_stderr)
  }
}

// -- Filesystem --------------------------------------------------------------

/// Read a UTF-8 file, reporting the operation and path on error.
pub fn read(path: String) -> Result(String, Snag) {
  simplifile.read(path)
  |> file_result("Reading " <> path)
}

/// Read a UTF-8 file if present, reporting other errors with context.
pub fn read_if_exists(path: String) -> Result(Option(String), Snag) {
  case simplifile.read(path) {
    Ok(contents) -> Ok(Some(contents))
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) -> file_error(error, "Reading " <> path)
  }
}

/// Read a binary file, reporting the operation and path on error.
pub fn read_bits(path: String) -> Result(BitArray, Snag) {
  simplifile.read_bits(path)
  |> file_result("Reading " <> path)
}

/// Write a UTF-8 file, reporting the operation and path on error.
pub fn write(path: String, contents: String) -> Result(Nil, Snag) {
  use Nil <- result.try(create_parent_directory(path))
  simplifile.write(path, contents)
  |> file_result("Writing " <> path)
}

/// Write a binary file, reporting the operation and path on error.
pub fn write_bits(path: String, contents: BitArray) -> Result(Nil, Snag) {
  use Nil <- result.try(create_parent_directory(path))
  simplifile.write_bits(path, contents)
  |> file_result("Writing " <> path)
}

/// Write an executable file, creating its parent directory when needed.
pub fn write_executable(path: String, contents: BitArray) -> Result(Nil, Snag) {
  use Nil <- result.try(write_bits(path, contents))
  simplifile.set_permissions_octal(path, 0o755)
  |> file_result("Setting executable permissions on " <> path)
}

/// Create a directory and its parents, reporting the path on error.
pub fn create_directory_all(path: String) -> Result(Nil, Snag) {
  simplifile.create_directory_all(path)
  |> file_result("Creating directory " <> path)
}

/// Read a directory if present, reporting other errors with context.
pub fn read_directory_if_exists(path: String) -> Result(List(String), Snag) {
  case simplifile.read_directory(path) {
    Ok(entries) -> Ok(entries)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> file_error(error, "Reading directory " <> path)
  }
}

/// Recursively list files if the path exists, reporting other errors with context.
pub fn get_files_if_exists(path: String) -> Result(List(String), Snag) {
  case simplifile.get_files(path) {
    Ok(files) -> Ok(files)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> file_error(error, "Listing files in " <> path)
  }
}

/// Return whether a file exists.
pub fn file_exists(path: String) -> Bool {
  simplifile.is_file(path) |> result.unwrap(False)
}

/// Return whether a directory exists.
pub fn directory_exists(path: String) -> Bool {
  simplifile.is_directory(path) |> result.unwrap(False)
}

/// Delete a path if present, reporting the path on error.
pub fn delete(path: String) -> Result(Nil, Snag) {
  case simplifile.delete(path) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) -> file_error(error, "Deleting " <> path)
  }
}

/// Delete multiple paths, reporting them on error.
pub fn delete_all(paths: List(String)) -> Result(Nil, Snag) {
  simplifile.delete_all(paths: paths)
  |> file_result("Deleting " <> string.join(paths, ", "))
}

/// Replace a path with an empty directory.
pub fn reset_directory(path: String) -> Result(Nil, Snag) {
  use Nil <- result.try(delete(path))
  create_directory_all(path)
}

/// Copy a directory tree when it exists.
pub fn copy_directory_if_exists(
  source: String,
  destination: String,
) -> Result(Nil, Snag) {
  case check_directory(source) {
    Ok(False) -> Ok(Nil)
    Ok(True) -> copy_directory(source, destination)
    Error(error) -> Error(error)
  }
}

/// Symlink a path using an absolute target, falling back to copying it.
pub fn link_or_copy(source: String, destination: String) -> Result(Nil, Snag) {
  use absolute_source <- result.try(case filepath.is_absolute(source) {
    True -> Ok(source)
    False ->
      simplifile.current_directory()
      |> file_result("Reading current directory")
      |> result.map(filepath.join(_, source))
  })

  case simplifile.create_symlink(to: absolute_source, from: destination) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> copy(source, destination)
  }
}

/// Symlink a directory when present, falling back to copying it.
pub fn link_or_copy_directory_if_exists(
  source: String,
  destination: String,
) -> Result(Nil, Snag) {
  case check_directory(source) {
    Ok(False) -> Ok(Nil)
    Ok(True) -> link_or_copy(source, destination)
    Error(error) -> Error(error)
  }
}

/// Replace a path with a directory symlink, falling back to copying it.
pub fn replace_with_link_or_copy_directory(
  source: String,
  destination: String,
) -> Result(Nil, Snag) {
  use source_exists <- result.try(check_directory(source))
  case source_exists {
    False ->
      snag.error("Directory does not exist")
      |> snag.context("Linking or copying " <> source <> " to " <> destination)
    True -> {
      use Nil <- result.try(delete(destination))
      link_or_copy(source, destination)
    }
  }
}

/// Delete entries in a directory whose names start with a prefix.
///
/// This is best-effort cleanup: missing directories and deletion errors are
/// ignored.
pub fn delete_with_prefix(directory: String, prefix: String) -> Nil {
  let entries = case simplifile.read_directory(directory) {
    Ok(entries) -> entries
    Error(_) -> []
  }
  list.each(entries, fn(entry) {
    case string.starts_with(entry, prefix) {
      True -> {
        let _ = simplifile.delete(filepath.join(directory, entry))
        Nil
      }
      False -> Nil
    }
  })
}

/// Create a temporary file for a callback and remove it afterwards.
pub fn with_temporary_file(
  directory directory: String,
  prefix prefix: String,
  run run: fn(String) -> value,
) -> Result(value, Snag) {
  use Nil <- result.try(create_directory_all(directory))
  temporary.create(
    temporary.file()
      |> temporary.in_directory(directory)
      |> temporary.with_prefix(prefix),
    run:,
  )
  |> file_result("Creating temporary file in " <> directory)
}

// -- HTTP --------------------------------------------------------------------

/// Fetch a UTF-8 HTTP response, reporting the URL on error.
pub fn fetch(
  url: String,
  headers: List(#(String, String)),
) -> Result(String, Snag) {
  use req <- result.try(
    request.to(url)
    |> snag.replace_error("Invalid URL " <> url),
  )
  let req =
    list.fold(headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  httpc.configure()
  |> httpc.follow_redirects(True)
  |> httpc.dispatch(req)
  |> snag.map_error(describe_http_error)
  |> snag.context("Getting " <> url)
  |> result.map(fn(response) { response.body })
}

/// Download a binary HTTP response, reporting the URL on error.
pub fn fetch_bits(url: String, timeout: Int) -> Result(BitArray, Snag) {
  use req <- result.try(
    request.to(url)
    |> snag.replace_error("Invalid URL " <> url),
  )
  let req = request.set_body(req, <<>>)
  httpc.configure()
  |> httpc.timeout(timeout)
  |> httpc.follow_redirects(True)
  |> httpc.dispatch_bits(req)
  |> snag.map_error(describe_http_error)
  |> snag.context("Downloading " <> url)
  |> result.map(fn(response) { response.body })
}

// -- Archives ----------------------------------------------------------------

/// Extract an archive to disk, reporting its destination on error.
pub fn extract_archive(
  archive: BitArray,
  destination: String,
) -> Result(Nil, Snag) {
  use Nil <- result.try(create_directory_all(destination))
  zip.extract(archive, destination)
  |> snag.map_error(zip.describe_error)
  |> snag.context("Extracting archive to " <> destination)
  |> result.replace(Nil)
}

// -- Runtime -----------------------------------------------------------------

/// Stop the Erlang runtime with the given status code.
@external(erlang, "erlang", "halt")
pub fn halt(status_code: Int) -> Nil

// -- Filesystem internals ----------------------------------------------------

fn copy(source: String, destination: String) -> Result(Nil, Snag) {
  use source_is_directory <- result.try(check_directory(source))
  case source_is_directory {
    True ->
      simplifile.copy_directory(at: source, to: destination)
      |> file_result("Copying directory " <> source <> " to " <> destination)
    False ->
      simplifile.copy_file(at: source, to: destination)
      |> file_result("Copying file " <> source <> " to " <> destination)
  }
}

fn check_directory(path: String) -> Result(Bool, Snag) {
  simplifile.is_directory(path)
  |> file_result("Checking directory " <> path)
}

fn copy_directory(source: String, destination: String) -> Result(Nil, Snag) {
  simplifile.copy_directory(at: source, to: destination)
  |> file_result("Copying directory " <> source <> " to " <> destination)
}

fn create_parent_directory(path: String) -> Result(Nil, Snag) {
  create_directory_all(filepath.directory_name(path))
}

fn file_result(
  result: Result(value, simplifile.FileError),
  context: String,
) -> Result(value, Snag) {
  result
  |> snag.map_error(simplifile.describe_error)
  |> snag.context(context)
}

fn file_error(
  error: simplifile.FileError,
  context: String,
) -> Result(value, Snag) {
  snag.error(simplifile.describe_error(error))
  |> snag.context(context)
}

// -- HTTP internals ----------------------------------------------------------

fn describe_http_error(error: httpc.HttpError) -> String {
  case error {
    httpc.InvalidUtf8Response -> "Invalid utf-8 body"
    httpc.FailedToConnect(ip4:, ip6: _) ->
      "Failed to connect: " <> describe_connect_error(ip4)
    httpc.ResponseTimeout -> "Timeout"
  }
}

fn describe_connect_error(error: httpc.ConnectError) -> String {
  case error {
    httpc.Posix(code:) -> code
    httpc.TlsAlert(code:, detail:) ->
      "TLS Error: " <> detail <> " (" <> code <> ")"
  }
}
