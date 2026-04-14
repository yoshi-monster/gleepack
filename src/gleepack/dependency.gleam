import gleam/dict
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleepack/project.{type Manifest, type Project}
import snag.{type Snag}

type StackItem {
  Visit(String)
  Emit(Project)
}

pub fn production(
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

// Like dependency.production but also includes dev_dependencies, tagging
// packages only reachable via dev deps with is_dev: True.
pub fn all(project: Project, manifest: Manifest) -> Result(List(Project), Snag) {
  // Compute prod-reachable names first.
  use prod_dependencies <- result.try(
    project.dependencies
    |> gleam_last(manifest)
    |> list.map(Visit)
    |> dependencies_loop(set.new(), [], manifest),
  )

  // Walk all deps including dev.
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

  // Tag packages not reachable from prod as dev-only.
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

          dependencies_loop(stack, set.insert(visited, name), sorted, manifest)
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
