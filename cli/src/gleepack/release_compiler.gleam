//// Renders the Erlang entrypoint module and assembles a release archive for a
//// packaged Gleam application.

import child_process
import filepath
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleepack/app_file
import gleepack/beam_compiler.{type BeamCompiler}
import gleepack/config
import gleepack/emu_args
import gleepack/project.{type Project, Gleam}
import gleepack/project_compiler
import gleepack/target.{type InstalledTarget}
import gleepack/zip
import simplifile
import snag.{type Snag}

// -- OTP app discovery -------------------------------------------------------

/// Discover OTP applications required by reading compiled `.app` files and
/// walking their `applications` dependencies transitively.
///
/// Any app listed in an `applications` field that is not itself a compiled
/// dependency is treated as an OTP app from the toolchain.
pub fn discover_otp_apps(
  dependencies: List(Project),
  otp_directory: String,
) -> Result(List(String), Snag) {
  let project_apps = set.from_list(list.map(dependencies, fn(d) { d.otp_app }))

  use seed <- result.try(
    list.try_fold(dependencies, [], fn(acc, dep) {
      let path =
        config.build_dir
        |> filepath.join(dep.name)
        |> filepath.join("ebin")
        |> filepath.join(dep.otp_app <> ".app")
      case app_file.read(path) {
        Ok(app) -> Ok(list.append(acc, app.applications))
        Error(_) -> Ok(acc)
      }
    }),
  )

  let otp_seed =
    ["kernel", "stdlib", ..seed]
    |> list.filter(fn(a) { !set.contains(project_apps, a) })
    |> list.unique

  walk_otp_deps(otp_seed, project_apps, otp_directory, set.new())
}

fn walk_otp_deps(
  frontier: List(String),
  project_apps: Set(String),
  otp_directory: String,
  seen: Set(String),
) -> Result(List(String), Snag) {
  case frontier {
    [] -> Ok(set.to_list(seen))
    [app, ..rest] ->
      case set.contains(seen, app) {
        True -> walk_otp_deps(rest, project_apps, otp_directory, seen)
        False -> {
          let seen = set.insert(seen, app)
          let app_path =
            otp_directory
            |> filepath.join("lib")
            |> filepath.join(app)
            |> filepath.join("ebin")
            |> filepath.join(app <> ".app")
          let new_apps = case app_file.read(app_path) {
            Ok(data) ->
              list.filter(data.applications, fn(a) {
                !set.contains(project_apps, a) && !set.contains(seen, a)
              })
            Error(_) -> []
          }
          walk_otp_deps(
            list.append(rest, new_apps),
            project_apps,
            otp_directory,
            seen,
          )
        }
      }
  }
}

// -- File collection ---------------------------------------------------------

/// Collect .beam, .app, and priv files for all production dependencies.
pub fn collect_dependency_files(
  dependencies: List(Project),
) -> Result(List(#(String, BitArray)), Snag) {
  use files, dep <- list.try_fold(dependencies, [])
  use beam_files <- result.try(collect_ebin_files(dep))
  use priv_files <- result.try(collect_priv_files(dep))

  Ok(
    files
    |> list.fold(over: beam_files, with: list.prepend)
    |> list.fold(over: priv_files, with: list.prepend),
  )
}

fn collect_ebin_files(dep: Project) -> Result(List(#(String, BitArray)), Snag) {
  let src_dir =
    config.build_dir |> filepath.join(dep.name) |> filepath.join("ebin")
  let dst_dir = "lib/" <> dep.otp_app <> "/ebin"

  use file_paths <- result.try(get_files(src_dir, dep.name))

  list.try_fold(file_paths, [], fn(acc, src_path) {
    let file_name = filepath.base_name(src_path)
    // Skip gleam@@ internal modules
    use <- bool.guard(string.contains(file_name, "@@"), Ok(acc))
    case filepath.extension(file_name) {
      Ok("beam") | Ok("app") -> {
        use contents <- result.try(read_bits(src_path))
        Ok([#(filepath.join(dst_dir, file_name), contents), ..acc])
      }
      _ -> Ok(acc)
    }
  })
}

fn collect_priv_files(dep: Project) -> Result(List(#(String, BitArray)), Snag) {
  let src_dir = filepath.join(dep.src, "priv")
  let dst_dir = "lib/" <> dep.otp_app <> "/priv"

  use file_paths <- result.try(get_files(src_dir, dep.name))

  list.try_fold(file_paths, [], fn(acc, src_path) {
    case filepath.extension(src_path) {
      Ok("so") | Ok("dll") | Ok("dylib") | Ok("o") | Error(Nil) -> Ok(acc)
      Ok(_) -> {
        use contents <- result.try(read_bits(src_path))
        let relative = string.remove_prefix(src_path, src_dir)
        Ok([#(filepath.join(dst_dir, relative), contents), ..acc])
      }
    }
  })
}

/// Collect .beam and .app files for OTP applications from the installed toolchain.
pub fn collect_otp_apps(
  apps: List(String),
  otp_directory: String,
) -> Result(List(#(String, BitArray)), Snag) {
  use files, app <- list.try_fold(apps, [])

  let ebin_dir = "lib/" <> app <> "/ebin"
  let src_dir = filepath.join(otp_directory, ebin_dir)

  use file_paths <- result.try(get_files(src_dir, app))

  use new_files <- result.try(
    list.try_fold(file_paths, [], fn(acc, src_path) {
      let file_name = filepath.base_name(src_path)
      case filepath.extension(file_name) {
        Ok("beam") | Ok("app") -> {
          use contents <- result.try(read_bits(src_path))
          Ok([#(filepath.join(ebin_dir, file_name), contents), ..acc])
        }
        _ -> Ok(acc)
      }
    }),
  )

  Ok(list.append(files, new_files))
}

// -- Assembly ----------------------------------------------------------------

/// Assemble a release archive from already-compiled files.
///
/// Discovers OTP app dependencies by reading compiled `.app` files, collects
/// all dependency and OTP application files, adds the entrypoint beam and
/// emulator args, and builds a zip archive in memory.
pub fn assemble(
  project project: Project,
  entrypoint_beam entrypoint_beam: BitArray,
  dependencies dependencies: List(Project),
  otp_directory otp_directory: String,
) -> Result(BitArray, Snag) {
  use otp_apps <- result.try(
    discover_otp_apps(dependencies, otp_directory)
    |> snag.context("Discovering OTP application dependencies"),
  )
  use dep_files <- result.try(
    collect_dependency_files(dependencies)
    |> snag.context("Collecting dependency files"),
  )
  use otp_files <- result.try(
    collect_otp_apps(otp_apps, otp_directory)
    |> snag.context("Collecting OTP application files"),
  )
  use boot_script <- result.try(
    read_bits(filepath.join(otp_directory, "start.boot")),
  )

  let erl_args = render_erl_args(project)

  let builder =
    zip.new()
    |> zip.store_extensions([".beam"])

  let builder =
    zip.add(
      builder,
      at: "lib/" <> project.otp_app <> "/ebin/gleepack_main.beam",
      containing: entrypoint_beam,
    )

  let builder =
    list.fold(dep_files, builder, fn(builder, file) {
      zip.add(builder, at: file.0, containing: file.1)
    })

  let builder =
    list.fold(otp_files, builder, fn(builder, file) {
      zip.add(builder, at: file.0, containing: file.1)
    })

  let builder =
    zip.add(
      builder,
      at: "erl_args",
      containing: bit_array.from_string(erl_args),
    )

  let builder = zip.add(builder, at: "start.boot", containing: boot_script)

  Ok(zip.to_bits(builder))
}

// -- Full build pipeline -----------------------------------------------------

/// Build a complete release archive: compile all dependencies, render and
/// compile the entrypoint, then assemble into a zip.
pub fn build(
  project project: Project,
  module module: String,
  dependencies dependencies: List(Project),
  compile_dependencies compile_dependencies: List(Project),
  target target: InstalledTarget,
) -> Result(BitArray, Snag) {
  // Start the beam compiler once — shared between project and entrypoint compilation.
  use compiler <- result.try(
    beam_compiler.start(target)
    |> snag.context("Starting BEAM compiler"),
  )

  let result =
    do_build(
      project,
      module,
      dependencies,
      compile_dependencies,
      target,
      compiler,
    )

  // Always stop the compiler, even on failure.
  beam_compiler.stop(compiler)
  result
}

fn do_build(
  project: Project,
  module: String,
  dependencies: List(Project),
  compile_dependencies: List(Project),
  target: InstalledTarget,
  compiler: BeamCompiler,
) -> Result(BitArray, Snag) {
  // Compile all packages
  use Nil <- result.try(
    project_compiler.compile(compile_dependencies, target, compiler)
    |> snag.context("Compiling project"),
  )

  // Render and compile entrypoint
  use entrypoint_source <- result.try(render(project, module))
  use entrypoint_beam <- result.try(
    compile_entrypoint(entrypoint_source, project, compiler)
    |> snag.context("Building entrypoint"),
  )

  assemble(
    project:,
    entrypoint_beam:,
    dependencies:,
    otp_directory: target.otp_directory,
  )
}

fn compile_entrypoint(
  source: String,
  project: Project,
  compiler: BeamCompiler,
) -> Result(BitArray, Snag) {
  let erl_path = filepath.join(config.build_dir, "gleepack_main.erl")
  let ebin_path =
    config.build_dir
    |> filepath.join(project.name)
    |> filepath.join("ebin")

  use Nil <- result.try(
    simplifile.create_directory_all(ebin_path)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Creating ebin directory"),
  )

  use Nil <- result.try(
    simplifile.write(erl_path, source)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Writing gleepack_main.erl"),
  )

  use Nil <- result.try(
    beam_compiler.compile(compiler, ebin_path, erl_path)
    |> snag.map_error(child_process.describe_write_error)
    |> snag.context("Sending entrypoint to BEAM compiler"),
  )

  // Wait for the single compile response.
  let selector =
    process.new_selector()
    |> beam_compiler.select(compiler)

  use msg <- result.try(
    case process.selector_receive(from: selector, within: 30_000) {
      Error(Nil) -> snag.error("Timed out compiling entrypoint")
      Ok(msg) -> Ok(msg)
    },
  )

  use Nil <- result.try(case beam_compiler.handle_msg(compiler, msg) {
    beam_compiler.Running(compiled: [_], failed: [], ..) -> Ok(Nil)
    beam_compiler.Running(failed:, ..) ->
      snag.error("Entrypoint compilation failed: " <> string.join(failed, ", "))
    beam_compiler.Exited(code) ->
      snag.error("BEAM compiler exited with code " <> int.to_string(code))
  })

  let beam_path = filepath.join(ebin_path, "gleepack_main.beam")
  simplifile.read_bits(beam_path)
  |> snag.map_error(simplifile.describe_error)
  |> snag.context("Reading compiled gleepack_main.beam")
}

// -- Entrypoint rendering ----------------------------------------------------

/// Render the gleepack_main.erl entrypoint source for `project`, calling `module` as the entry point.
fn render(project: Project, module: String) -> Result(String, Snag) {
  use template <- result.try(
    simplifile.read(filepath.join(config.priv_dir(), "gleepack_main.erl"))
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Rending gleepack_main.erl template"),
  )

  let erl_module = string.replace(module, "/", "@")

  let template =
    template
    |> string.replace("{{APPLICATION}}", project.name)
    |> string.replace("{{MODULE}}", erl_module)

  Ok(template)
}

// -- Erl args ----------------------------------------------------------------

/// Render the erl_args file content for a release.
///
/// Combines the project's extra_emu_args with structural flags and the
/// `-run gleepack_main main` start command.
fn render_erl_args(project: Project) -> String {
  let extra = case project {
    Gleam(extra_emu_args:, ..) ->
      option.unwrap(extra_emu_args, emu_args.default)
    _ -> emu_args.default
  }

  emu_args.render(emu_args.parse(extra))
}

// -- Helpers -----------------------------------------------------------------

fn get_files(dir: String, context: String) -> Result(List(String), Snag) {
  case simplifile.get_files(dir) {
    Ok(paths) -> Ok(paths)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      snag.error(simplifile.describe_error(error))
      |> snag.context("Could not list files for " <> context)
  }
}

fn read_bits(path: String) -> Result(BitArray, Snag) {
  simplifile.read_bits(path)
  |> snag.map_error(simplifile.describe_error)
  |> snag.context("Reading " <> path)
}
