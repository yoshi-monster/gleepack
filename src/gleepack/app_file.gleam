import gleam/dynamic/decode.{DecodeError} as _
import gleam/option
import gleam/result
import gleepack/eterm/decode.{type DecodeError}
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
  ParseError(List(DecodeError))
  ReadError(simplifile.FileError)
}

/// Describe an app_file error as a human-readable string.
pub fn describe_error(error: Error) -> String {
  case error {
    ParseError([]) -> "parse error: unknown"
    ParseError([DecodeError(expected:, found:, path: []), ..]) ->
      "parse error: expected " <> expected <> ", found " <> found
    ParseError([DecodeError(expected:, found:, path: [p, ..]), ..]) ->
      "parse error: expected " <> expected <> ", found " <> found <> " at " <> p
    ReadError(e) -> simplifile.describe_error(e)
  }
}

/// Parse the content of a `.app` file.
pub fn parse(content: String) -> Result(AppFile, Error) {
  let mod_value_decoder = {
    use m <- decode.element(0, decode.atom())
    decode.success(m)
  }

  let decoder = {
    use name <- decode.element(1, decode.atom())
    use vsn <- decode.element(2, decode.proplist("vsn", decode.string()))
    use description <- decode.element(2, {
      decode.optional_proplist("description", decode.string())
    })
    use modules <- decode.element(2, {
      decode.proplist("modules", decode.list(decode.atom()))
    })
    use applications <- decode.element(2, {
      decode.proplist("applications", decode.list(decode.atom()))
    })
    use start_module <- decode.element(2, {
      decode.optional_proplist("mod", mod_value_decoder)
    })

    decode.success(AppFile(
      name:,
      version: vsn,
      description: option.unwrap(description, ""),
      modules:,
      applications:,
      start_module:,
    ))
  }

  decode.parse(on: content, run: decoder)
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
