import child_process
import child_process/stdio
import filepath
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleepack/config
import gleepack/mode.{type Mode}
import gleepack/project.{type Manifest, type Project}
import gleepack/target
import simplifile
import snag.{type Snag}

type StackItem {
  Visit(String)
  Emit(Project)
}

/// Download all dependencies and prepare them for compilation.
///
/// Runs `gleam deps download` for the entry project — this resolves the
/// full transitive closure of path deps into the root `manifest.toml`. Each
/// path dep's `gleam.toml`, `src/`, and `priv/` (when present) is then
/// mirrored into `build/packages/<name>` so that test/ and dev/ are not
/// picked up by `gleam compile-package`. Mirroring prefers symlinks and
/// falls back to copying when the platform does not support them.
///
/// The returned manifest has path deps' `src` rewritten to the mirror
/// location.
pub fn download(
  available available: List(target.Target),
) -> Result(Manifest, Snag) {
  use _ <- result.try(gleam_deps_download("."))
  use cwd <- result.try(
    simplifile.current_directory()
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Reading current directory"),
  )

  use manifest <- result.try(project.manifest(available))

  use rewritten <- result.try({
    use acc, #(name, p) <- list.try_fold(dict.to_list(manifest), [])
    case p {
      project.Gleam(is_local: True, src:, name: dep_name, ..) if src != "." -> {
        use _ <- result.map(mirror_path_dep(dep_name, src, cwd))
        [#(name, project.Gleam(..p, src: mirror_dest(dep_name))), ..acc]
      }
      _ -> Ok([#(name, p), ..acc])
    }
  })

  Ok(dict.from_list(rewritten))
}

fn mirror_dest(name: String) -> String {
  filepath.join(config.packages_dir, name)
}

fn mirror_path_dep(
  name: String,
  src: String,
  cwd: String,
) -> Result(Nil, Snag) {
  let dest = mirror_dest(name)
  // Wipe any prior content so leftovers from previous runs (or whatever
  // `gleam deps download` placed here) don't leak into the compile. Safe
  // for symlinks too: simplifile.delete uses read_link_info, so symlink
  // *targets* are not followed.
  let _ = simplifile.delete(dest)
  use _ <- result.try(
    simplifile.create_directory_all(dest)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Creating " <> dest),
  )
  use _ <- result.try(
    mirror_entry(
      filepath.join(src, "gleam.toml"),
      filepath.join(dest, "gleam.toml"),
      cwd,
    )
    |> snag.context("Mirroring gleam.toml from " <> src),
  )
  use _ <- result.try(
    mirror_entry(filepath.join(src, "src"), filepath.join(dest, "src"), cwd)
    |> snag.context("Mirroring src/ from " <> src),
  )
  let priv_src = filepath.join(src, "priv")
  case simplifile.is_directory(priv_src) {
    Ok(True) ->
      mirror_entry(priv_src, filepath.join(dest, "priv"), cwd)
      |> snag.context("Mirroring priv/ from " <> src)
    _ -> Ok(Nil)
  }
}

fn mirror_entry(
  source: String,
  dest: String,
  cwd: String,
) -> Result(Nil, Snag) {
  let abs_source = case filepath.is_absolute(source) {
    True -> source
    False -> filepath.join(cwd, source)
  }
  case simplifile.create_symlink(to: abs_source, from: dest) {
    Ok(_) -> Ok(Nil)
    Error(_) -> copy_entry(source, dest)
  }
}

fn copy_entry(source: String, dest: String) -> Result(Nil, Snag) {
  case simplifile.is_directory(source) {
    Ok(True) ->
      simplifile.copy_directory(at: source, to: dest)
      |> snag.map_error(simplifile.describe_error)
      |> snag.context("Copying directory " <> source)
    _ ->
      simplifile.copy_file(at: source, to: dest)
      |> snag.map_error(simplifile.describe_error)
      |> snag.context("Copying file " <> source)
  }
}

fn gleam_deps_download(in directory: String) -> Result(Nil, Snag) {
  case
    child_process.from_name("gleam")
    |> child_process.cwd(directory)
    |> child_process.args(["deps", "download"])
    |> child_process.run(stdio.inherit())
  {
    Ok(child_process.Output(status_code: 0, output: _)) -> Ok(Nil)
    Ok(child_process.Output(status_code:, output: _)) ->
      snag.error(
        "gleam deps download failed with status code "
        <> int.to_string(status_code),
      )
    Error(error) -> snag.error(child_process.describe_start_error(error))
  }
  |> snag.context("Running gleam deps download in " <> directory)
}

/// Resolve the dependencies that should be bundled into the release for the
/// given mode: production-only for `Release`, all dependencies (including dev)
/// for `Debug` and `Shell`.
pub fn for_mode(
  mode: Mode,
  project: Project,
  manifest: Manifest,
) -> Result(List(Project), Snag) {
  case mode.includes_dev(mode) {
    True -> all(project, manifest)
    False -> production(project, manifest)
  }
}

fn production(
  project: Project,
  manifest: Manifest,
) -> Result(List(Project), Snag) {
  use dependencies <- result.try(
    project.dependencies
    |> gleam_last(manifest)
    |> list.map(Visit)
    |> dependencies_loop(set.new(), [], manifest),
  )

  Ok(list.reverse([project, ..dependencies]))
}

// Like dependency.production but also includes the root project's
// dev_dependencies, tagging packages only reachable via dev deps with
// is_dev: True.
pub fn all(
  project: Project,
  manifest: Manifest,
) -> Result(List(Project), Snag) {
  use prod_dependencies <- result.try(
    project.dependencies
    |> gleam_last(manifest)
    |> list.map(Visit)
    |> dependencies_loop(set.new(), [], manifest),
  )

  let all_dependencies = case project {
    project.Gleam(dev_dependencies:, dependencies:, ..) ->
      list.append(dependencies, dev_dependencies)
    _ -> project.dependencies
  }

  use all_dependencies <- result.try(
    all_dependencies
    |> gleam_last(manifest)
    |> list.map(Visit)
    |> dependencies_loop(set.new(), [], manifest),
  )

  let prod_names =
    list.map(prod_dependencies, fn(p) { p.name })
    |> set.from_list

  let all_dependencies =
    list.map(all_dependencies, fn(dependency) {
      case set.contains(prod_names, dependency.name) {
        True -> dependency
        False -> set_is_dev(dependency, True)
      }
    })

  Ok(list.reverse([project, ..all_dependencies]))
}

fn dependencies_loop(
  stack: List(StackItem),
  visited: Set(String),
  sorted: List(Project),
  manifest: Manifest,
) -> Result(List(Project), Snag) {
  case stack {
    [] -> Ok(sorted)

    [Emit(dependency), ..stack] ->
      dependencies_loop(stack, visited, [dependency, ..sorted], manifest)

    [Visit(name), ..stack] -> {
      case set.contains(visited, name) {
        True -> dependencies_loop(stack, visited, sorted, manifest)
        False -> {
          use dependency <- result.try(
            dict.get(manifest, name)
            |> snag.replace_error("Dependency not found in manifest: " <> name),
          )

          let stack =
            dependency.dependencies
            |> gleam_last(manifest)
            |> list.fold([Emit(dependency), ..stack], fn(stack, name) {
              case set.contains(visited, name) {
                True -> stack
                False -> [Visit(name), ..stack]
              }
            })

          let visited = set.insert(visited, name)

          dependencies_loop(stack, visited, sorted, manifest)
        }
      }
    }
  }
}

// Sort a list of dependency names so non-Gleam packages come first.
// When folded onto a stack (LIFO), Gleam packages end up on top and are
// therefore visited first, pushing non-Gleam packages as late as possible.
fn gleam_last(names: List(String), manifest: Manifest) -> List(String) {
  let is_gleam = fn(name) {
    case dict.get(manifest, name) {
      Ok(project.Gleam(..)) -> True
      _ -> False
    }
  }
  let #(gleam, other) = list.partition(names, is_gleam)
  list.append(gleam, other)
}

fn set_is_dev(project: Project, is_dev: Bool) -> Project {
  case project {
    project.Gleam(..) -> project.Gleam(..project, is_dev:)
    project.Rebar3(..) -> project.Rebar3(..project, is_dev:)
    project.Mix(..) -> project.Mix(..project, is_dev:)
  }
}
