import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
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
  GleamProject(
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
  )
  Rebar3Project(
    name: String,
    version: String,
    otp_app: String,
    dependencies: List(String),
    is_dev: Bool,
    src: String,
  )
  MixProject(
    name: String,
    version: String,
    otp_app: String,
    dependencies: List(String),
    is_dev: Bool,
    src: String,
  )
}

pub fn read(from dir: String) -> Result(Project, Snag) {
  use file_contents <- result.try(
    simplifile.read(filepath.join(dir, "gleam.toml"))
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Could not read gleam.toml"),
  )

  use project_file <- result.try(
    tom.parse(file_contents)
    |> snag.map_error(tom_parse_error)
    |> snag.context("Could not parse gleam.toml"),
  )

  parse_project(project_file, dir)
  |> snag.map_error(tom_get_error)
  |> snag.context("Could not read gleam.toml")
}

fn parse_project(
  project_file: Dict(String, Toml),
  src: String,
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

  Ok(GleamProject(
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
  ))
}

fn optional(result: Result(a, tom.GetError)) -> Result(Option(a), tom.GetError) {
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

// -- DEPENDENCIES ------------------------------------------------------------

type StackItem {
  Visit(String)
  Emit(Project)
}

pub fn read_dependencies(project: Project) -> Result(List(Project), Snag) {
  use manifest <- result.try(read_manifest())

  let stack =
    project.dependencies
    |> gleam_last(manifest)
    |> list.map(Visit)

  use sorted <- result.try(dependencies_loop(stack, set.new(), [], manifest))

  Ok(list.reverse([project, ..sorted]))
}

// Like read_dependencies but also includes dev_dependencies, tagging
// packages only reachable via dev deps with is_dev: True.
pub fn read_compile_dependencies(
  project: Project,
) -> Result(List(Project), Snag) {
  use manifest <- result.try(read_manifest())

  // Compute prod-reachable names first.
  let prod_stack =
    project.dependencies |> gleam_last(manifest) |> list.map(Visit)
  use prod_sorted <- result.try(dependencies_loop(
    prod_stack,
    set.new(),
    [],
    manifest,
  ))
  let prod_names =
    [project.name, ..list.map(prod_sorted, fn(p) { p.name })]
    |> set.from_list

  // Walk all deps including dev.
  let all_deps = case project {
    GleamProject(dev_dependencies:, dependencies:, ..) ->
      list.append(dependencies, dev_dependencies)
    _ -> project.dependencies
  }
  let all_stack = all_deps |> gleam_last(manifest) |> list.map(Visit)
  use all_sorted <- result.try(dependencies_loop(
    all_stack,
    set.new(),
    [],
    manifest,
  ))

  // Tag packages not reachable from prod as dev-only.
  let tagged =
    list.map(all_sorted, fn(dep) {
      case set.contains(prod_names, dep.name) {
        True -> dep
        False -> set_is_dev(dep, True)
      }
    })

  Ok(list.reverse([project, ..tagged]))
}

fn set_is_dev(project: Project, is_dev: Bool) -> Project {
  case project {
    GleamProject(..) -> GleamProject(..project, is_dev:)
    Rebar3Project(..) -> Rebar3Project(..project, is_dev:)
    MixProject(..) -> MixProject(..project, is_dev:)
  }
}

// Sort a list of dependency names so non-Gleam packages come first.
// When folded onto a stack (LIFO), Gleam packages end up on top and are
// therefore visited first, pushing non-Gleam packages as late as possible.
fn gleam_last(
  names: List(String),
  manifest: Dict(String, Project),
) -> List(String) {
  let is_gleam = fn(name) {
    case dict.get(manifest, name) {
      Ok(GleamProject(..)) -> True
      _ -> False
    }
  }
  let #(gleam, other) = list.partition(names, is_gleam)
  list.fold(other, gleam, list.prepend)
}

fn dependencies_loop(
  stack: List(StackItem),
  visited: Set(String),
  sorted: List(Project),
  manifest: Dict(String, Project),
) -> Result(List(Project), Snag) {
  case stack {
    [] -> Ok(sorted)

    [Emit(dependency), ..stack] ->
      dependencies_loop(stack, visited, [dependency, ..sorted], manifest)

    [Visit(name), ..stack] -> {
      case set.contains(visited, name) {
        True -> dependencies_loop(stack, visited, sorted, manifest)
        False -> {
          use dep <- result.try(
            dict.get(manifest, name)
            |> snag.replace_error("Dependency not found in manifest: " <> name),
          )

          let stack =
            dep.dependencies
            |> gleam_last(manifest)
            |> list.fold([Emit(dep), ..stack], fn(stack, name) {
              case set.contains(visited, name) {
                True -> stack
                False -> [Visit(name), ..stack]
              }
            })

          dependencies_loop(stack, set.insert(visited, name), sorted, manifest)
        }
      }
    }
  }
}

fn read_manifest() -> Result(Dict(String, Project), Snag) {
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

  use name <- result.try(
    tom.get_string(pkg, ["name"]) |> snag.map_error(tom_get_error),
  )
  use version <- result.try(
    tom.get_string(pkg, ["version"]) |> snag.map_error(tom_get_error),
  )

  use dependencies <- result.try(
    tom.get_array(pkg, ["requirements"])
    |> result.try(list.try_map(_, tom.as_string))
    |> snag.map_error(tom_get_error),
  )

  let otp_app = tom.get_string(pkg, ["otp_app"]) |> result.unwrap(name)

  let src = filepath.join("build/packages", name)

  use build_tools_toml <- result.try(
    tom.get_array(pkg, ["build_tools"]) |> snag.map_error(tom_get_error),
  )

  case build_tools_toml {
    [] -> snag.error("build_tools should not be empty")
    [tom.String("gleam"), ..] -> read(from: src)
    [tom.String("rebar3"), ..] | [tom.String("rebar"), ..] ->
      Ok(Rebar3Project(
        name:,
        version:,
        otp_app:,
        dependencies:,
        is_dev: False,
        src:,
      ))

    [tom.String("mix"), ..] ->
      Ok(MixProject(
        name:,
        version:,
        otp_app:,
        dependencies:,
        is_dev: False,
        src:,
      ))

    [tom.String(other), ..] ->
      snag.error(
        "build_tools should be one of \"gleam\", \"rebar3\" or \"mix\", actual: "
        <> string.inspect(other),
      )

    [_, ..] -> snag.error("build_tools needs to be an array of strings")
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
