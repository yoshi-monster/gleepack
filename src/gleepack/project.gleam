import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleepack/config
import gleepack/target
import simplifile
import snag.{type Snag}
import tom.{type Toml}

// -- PROJECT GLEAM.TOML ------------------------------------------------------

pub type Target {
  Erlang
  Javascript
}

pub type Project {
  Gleam(
    name: String,
    version: String,
    otp_app: String,
    dependencies: List(String),
    is_dev: Bool,
    src: String,
    // gleam-specific options
    is_local: Bool,
    dev_dependencies: List(String),
    target: Option(Target),
    extra_applications: List(String),
    application_start_module: Option(String),
    // gleepack options
    output: Option(String),
    module: Option(String),
    targets: List(target.Target),
    extra_emu_args: Option(String),
  )
  Rebar3(
    name: String,
    version: String,
    otp_app: String,
    dependencies: List(String),
    is_dev: Bool,
    src: String,
  )
  Mix(
    name: String,
    version: String,
    otp_app: String,
    dependencies: List(String),
    is_dev: Bool,
    src: String,
  )
}

pub type Manifest =
  Dict(String, Project)

pub fn read(from dir: String) -> Result(Project, Snag) {
  read_internal(dir, True)
}

fn read_internal(
  from dir: String,
  local is_local: Bool,
) -> Result(Project, Snag) {
  use file_contents <- result.try(
    simplifile.read(filepath.join(dir, "gleam.toml"))
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Could not read gleam.toml from " <> dir),
  )

  use project_file <- result.try(
    tom.parse(file_contents)
    |> snag.map_error(tom_parse_error)
    |> snag.context("Could not parse gleam.toml"),
  )

  parse_project(project_file, dir, is_local)
  |> snag.map_error(tom_get_error)
  |> snag.context("Could not parse gleam.toml")
}

fn parse_project(
  project_file: Dict(String, Toml),
  src: String,
  is_local: Bool,
) -> Result(Project, tom.GetError) {
  use name <- result.try(tom.get_string(project_file, ["name"]))
  use version <- result.try(tom.get_string(project_file, ["version"]))

  use dependencies <- result.try(
    tom.get_table(project_file, ["dependencies"])
    |> result.map(dict.keys)
    |> or([]),
  )

  use dev_dependencies <- result.try(
    tom.get_table(project_file, ["dev_dependencies"])
    |> result.or(tom.get_table(project_file, ["dev-dependencies"]))
    |> result.map(dict.keys)
    |> or([]),
  )

  use target <- result.try(case tom.get_string(project_file, ["target"]) {
    Error(tom.NotFound(..)) -> Ok(None)
    Error(e) -> Error(e)
    Ok("erlang") -> Ok(Some(Erlang))
    Ok("javascript") -> Ok(Some(Javascript))
    Ok(s) ->
      Error(tom.WrongType(
        key: ["target"],
        expected: "\"erlang\" or \"javascript\"",
        got: s,
      ))
  })

  use extra_applications <- result.try(
    tom.get_array(project_file, ["erlang", "extra_applications"])
    |> result.try(list.try_map(_, tom.as_string))
    |> or([]),
  )

  use application_start_module <- result.try(
    tom.get_string(project_file, ["erlang", "application_start_module"])
    |> optional,
  )

  use output <- result.try(
    tom.get_string(project_file, ["tools", config.app_name, "output"])
    |> optional,
  )

  use module <- result.try(
    tom.get_string(project_file, ["tools", config.app_name, "module"])
    |> optional,
  )

  use targets <- result.try(
    tom.get_array(project_file, ["tools", config.app_name, "targets"])
    |> result.try(list.try_map(_, tom.as_string))
    |> result.try(
      list.try_map(_, fn(target) {
        case target.from_string(target) {
          Ok(target) -> Ok(target)
          Error(Nil) ->
            Error(tom.WrongType(
              key: ["tools", config.app_name, "targets"],
              expected: "a valid gleepack target",
              got: target,
            ))
        }
      }),
    )
    |> or([]),
  )

  use extra_emu_args <- result.try(
    tom.get_string(project_file, ["tools", config.app_name, "extra_emu_args"])
    |> optional,
  )

  Ok(Gleam(
    name:,
    version:,
    otp_app: name,
    dependencies:,
    is_dev: False,
    src:,
    is_local:,
    dev_dependencies:,
    target:,
    extra_applications:,
    application_start_module:,
    output:,
    module:,
    targets:,
    extra_emu_args:,
  ))
}

// -- MANIFEST ----------------------------------------------------------------

pub fn manifest() -> Result(Manifest, Snag) {
  use contents <- result.try(
    simplifile.read("manifest.toml")
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Could not read manifest.toml"),
  )

  use manifest <- result.try(
    tom.parse(contents)
    |> snag.map_error(tom_parse_error)
    |> snag.context("Could not parse manifest.toml"),
  )

  use packages <- result.try(
    tom.get_array(manifest, ["packages"])
    |> snag.map_error(tom_get_error)
    |> snag.context("Could not read packages from manifest.toml"),
  )

  list.try_fold(packages, dict.new(), fn(acc, package) {
    use project <- result.try(read_manifest_package(package))
    Ok(dict.insert(acc, project.name, project))
  })
}

fn read_manifest_package(package: Toml) -> Result(Project, Snag) {
  use pkg <- result.try(
    package |> tom.as_table |> snag.map_error(tom_get_error),
  )

  use is_local <- result.try(
    tom.get_string(pkg, ["source"])
    |> result.map(fn(source) { source == "local" })
    |> snag.map_error(tom_get_error),
  )

  use name <- result.try(
    tom.get_string(pkg, ["name"]) |> snag.map_error(tom_get_error),
  )
  use version <- result.try(
    tom.get_string(pkg, ["version"]) |> snag.map_error(tom_get_error),
  )
  use src <- result.try(
    tom.get_string(pkg, ["path"])
    |> or(filepath.join("build/packages", name))
    |> snag.map_error(tom_get_error),
  )

  use dependencies <- result.try(
    tom.get_array(pkg, ["requirements"])
    |> result.try(list.try_map(_, tom.as_string))
    |> snag.map_error(tom_get_error),
  )

  let otp_app = tom.get_string(pkg, ["otp_app"]) |> result.unwrap(name)

  use build_tools_toml <- result.try(
    tom.get_array(pkg, ["build_tools"]) |> snag.map_error(tom_get_error),
  )

  case build_tools_toml {
    [] -> snag.error("build_tools should not be empty")
    [tom.String("gleam"), ..] -> read_internal(from: src, local: is_local)
    [tom.String("rebar3"), ..] | [tom.String("rebar"), ..] ->
      Ok(Rebar3(name:, version:, otp_app:, dependencies:, is_dev: False, src:))

    [tom.String("mix"), ..] ->
      Ok(Mix(name:, version:, otp_app:, dependencies:, is_dev: False, src:))

    [tom.String(other), ..] ->
      snag.error(
        "build_tools should be one of \"gleam\", \"rebar3\" or \"mix\", actual: "
        <> string.inspect(other),
      )

    [_, ..] -> snag.error("build_tools needs to be an array of strings")
  }
}

// -- HELPERS -----------------------------------------------------------------

fn optional(
  result: Result(a, tom.GetError),
) -> Result(Option(a), tom.GetError) {
  case result {
    Ok(value) -> Ok(Some(value))
    Error(tom.NotFound(..)) -> Ok(None)
    Error(tom.WrongType(..) as error) -> Error(error)
  }
}

fn or(result: Result(a, tom.GetError), default: a) -> Result(a, tom.GetError) {
  case result {
    Ok(_) -> result
    Error(tom.NotFound(..)) -> Ok(default)
    Error(tom.WrongType(..)) -> result
  }
}

fn tom_parse_error(error: tom.ParseError) -> String {
  case error {
    tom.KeyAlreadyInUse(key:) -> "Duplicate key " <> string.join(key, ".")
    tom.Unexpected(got:, expected:) ->
      "Expected "
      <> string.inspect(expected)
      <> ", but got "
      <> string.inspect(got)
  }
}

fn tom_get_error(error: tom.GetError) -> String {
  case error {
    tom.NotFound(key:) -> "Key " <> string.join(key, ".") <> " not found"
    tom.WrongType(key:, expected:, got:) ->
      "Value at "
      <> string.join(key, ".")
      <> " was of type "
      <> got
      <> ", but expected "
      <> expected
  }
}
