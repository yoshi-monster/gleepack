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

pub type Source {
  Hex
  Local
  Git
}

pub type Project {
  Gleam(
    source: Source,
    name: String,
    version: String,
    otp_app: String,
    dependencies: List(String),
    is_dev: Bool,
    src: String,
    // gleam-specific options
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
    source: Source,
    name: String,
    version: String,
    otp_app: String,
    dependencies: List(String),
    is_dev: Bool,
    src: String,
  )
  Mix(
    source: Source,
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

pub fn read(
  from dir: String,
  available available: List(target.Target),
) -> Result(Project, Snag) {
  read_internal(dir, Local, available)
}

fn read_internal(
  from dir: String,
  source source: Source,
  available available: List(target.Target),
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

  parse_project(project_file, dir, source, available)
  |> snag.map_error(tom_get_error)
  |> snag.context("Could not parse gleam.toml")
}

fn parse_project(
  project_file: Dict(String, Toml),
  src: String,
  source: Source,
  available: List(target.Target),
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
        case target.from_string(available, target) {
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
    source:,
    name:,
    version:,
    otp_app: name,
    dependencies:,
    is_dev: False,
    src:,
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

pub fn manifest(available: List(target.Target)) -> Result(Manifest, Snag) {
  manifest_from(".", available)
}

/// Read a manifest.toml from the given directory. `gleam deps download`
/// resolves the full transitive closure of path deps into this single file,
/// so no further merging is needed.
pub fn manifest_from(
  dir: String,
  available: List(target.Target),
) -> Result(Manifest, Snag) {
  read_manifest_packages(dir, available)
}

fn read_manifest_packages(
  dir: String,
  available: List(target.Target),
) -> Result(Manifest, Snag) {
  let path = filepath.join(dir, "manifest.toml")
  use contents <- result.try(
    simplifile.read(path)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Could not read " <> path),
  )

  use manifest <- result.try(
    tom.parse(contents)
    |> snag.map_error(tom_parse_error)
    |> snag.context("Could not parse " <> path),
  )

  use packages <- result.try(
    tom.get_array(manifest, ["packages"])
    |> snag.map_error(tom_get_error)
    |> snag.context("Could not read packages from " <> path),
  )

  list.try_fold(packages, dict.new(), fn(acc, package) {
    use project <- result.try(read_manifest_package(package, dir, available))
    Ok(dict.insert(acc, project.name, project))
  })
}

fn read_manifest_package(
  package: Toml,
  dir: String,
  available: List(target.Target),
) -> Result(Project, Snag) {
  use pkg <- result.try(
    package |> tom.as_table |> snag.map_error(tom_get_error),
  )

  use source <- result.try(case tom.get_string(pkg, ["source"]) {
    Ok("git") -> Ok(Git)
    Ok("local") -> Ok(Local)
    Ok("hex") -> Ok(Hex)
    Ok(_) ->
      snag.error(tom_get_error(tom.WrongType(["source"], "Source", "String")))
    Error(error) -> snag.error(tom_get_error(error))
  })

  use name <- result.try(
    tom.get_string(pkg, ["name"]) |> snag.map_error(tom_get_error),
  )
  use version <- result.try(
    tom.get_string(pkg, ["version"]) |> snag.map_error(tom_get_error),
  )
  use relative_src <- result.try(
    tom.get_string(pkg, ["path"])
    |> or(filepath.join("build/packages", name))
    |> snag.map_error(tom_get_error),
  )
  let src = filepath.join(dir, relative_src)

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
    [tom.String("gleam"), ..] -> read_internal(from: src, source:, available:)
    [tom.String("rebar3"), ..] | [tom.String("rebar"), ..] -> {
      let is_dev = False
      let project =
        Rebar3(source:, name:, version:, otp_app:, dependencies:, is_dev:, src:)
      Ok(project)
    }

    [tom.String("mix"), ..] -> {
      let is_dev = False
      let project =
        Mix(source:, name:, version:, otp_app:, dependencies:, is_dev:, src:)
      Ok(project)
    }

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
