/// Reads and writes Erlang OTP application resource (.app) files.
import gleam/dynamic/decode
import gleam/option
import gleam/result
import gleepack/eterm/decode as d
import gleepack/eterm/encode
import simplifile
import snag.{type Snag}

pub type AppFile {
  AppFile(
    name: String,
    version: String,
    description: String,
    modules: List(String),
    applications: List(String),
    start_module: option.Option(String),
  )
}

pub type Error {
  ParseError(List(decode.DecodeError))
  ReadError(simplifile.FileError)
}

/// Describe an app_file error as a human-readable string.
pub fn describe_error(error: Error) -> String {
  case error {
    ParseError([]) -> "parse error: unknown"
    ParseError([decode.DecodeError(expected:, found:, path: []), ..]) ->
      "parse error: expected " <> expected <> ", found " <> found
    ParseError([decode.DecodeError(expected:, found:, path: [p, ..]), ..]) ->
      "parse error: expected " <> expected <> ", found " <> found <> " at " <> p
    ReadError(e) -> simplifile.describe_error(e)
  }
}

/// Parse the content of a `.app` file.
pub fn parse(content: String) -> Result(AppFile, Error) {
  let mod_value_decoder = {
    use m <- d.element(0, d.atom())
    decode.success(m)
  }
  let decoder = {
    use name <- d.element(1, d.atom())
    use vsn <- d.element(2, d.proplist("vsn", d.string()))
    use description <- d.element(
      2,
      d.optional_proplist("description", d.string()),
    )
    use modules <- d.element(2, d.proplist("modules", decode.list(d.atom())))
    use applications <- d.element(
      2,
      d.proplist("applications", decode.list(d.atom())),
    )
    use start_module <- d.element(
      2,
      d.optional_proplist("mod", mod_value_decoder),
    )
    decode.success(AppFile(
      name:,
      version: vsn,
      description: option.unwrap(description, ""),
      modules:,
      applications:,
      start_module:,
    ))
  }
  d.parse(on: content, run: decoder)
  |> result.map_error(ParseError)
}

/// Read and parse a `.app` file from disk.
pub fn read(path: String) -> Result(AppFile, Snag) {
  use content <- result.try(
    simplifile.read(path)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Reading " <> path),
  )
  parse(content)
  |> snag.map_error(describe_error)
  |> snag.context("Parsing " <> path)
}

/// Serialise an `AppFile` to Erlang `.app` file syntax.
pub fn to_string(app: AppFile) -> String {
  let mod_entry = case app.start_module {
    option.None -> []
    option.Some(m) -> [
      #("mod", encode.tuple([encode.atom(m), encode.list([], encode.atom)])),
    ]
  }
  let props = [
    #("description", encode.string(app.description)),
    #("vsn", encode.string(app.version)),
    #("modules", encode.list(app.modules, encode.atom)),
    #("registered", encode.list([], encode.atom)),
    #("applications", encode.list(app.applications, encode.atom)),
    ..mod_entry
  ]
  encode.tuple([
    encode.atom("application"),
    encode.atom(app.name),
    encode.proplist(props),
  ])
  |> encode.to_pretty_string
}

/// Write an `AppFile` to disk.
pub fn write(app: AppFile, path: String) -> Result(Nil, Snag) {
  simplifile.write(path, to_string(app))
  |> snag.map_error(simplifile.describe_error)
  |> snag.context("Writing " <> path)
}
