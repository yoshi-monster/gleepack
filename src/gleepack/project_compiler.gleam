//// Drives a two-stage pipeline: compile packages to .erl (stage 1) while
//// concurrently compiling .erl to .beam via the beam compiler (stage 2).

import child_process.{type Process}
import child_process/stdio
import directories
import filepath
import gleam/bool
import gleam/deque.{type Deque as Queue} as queue
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import gleepack/app_file
import gleepack/beam_compiler.{type BeamCompiler}
import gleepack/config
import gleepack/project.{type Project, Gleam, Mix, Rebar3}
import gleepack/target.{type InstalledTarget}
import simplifile
import snag.{type Snag}

type Msg {
  CompileOutput(BitArray)
  CompileFinished(Int)
  BeamMsg(beam_compiler.Msg)
}

type LoopState {
  LoopState(
    target: InstalledTarget,
    compiler: BeamCompiler,
    // Maps package name -> otp_app for resolving .app dependencies.
    otp_apps: Dict(String, String),
    remaining: List(Project),
    in_flight: Option(#(Project, Process)),
    // Packages whose .erl files are queued in the beam compiler:
    // (name, remaining module count).
    pending: Queue(#(String, Int)),
  )
}

/// Compile all packages in `deps` to BEAM files under `config.build_dir`.
///
/// The caller provides a running `BeamCompiler` so the same instance can be
/// reused for later compilation steps (e.g. the release entrypoint).
pub fn compile(
  dependencies: List(Project),
  target: InstalledTarget,
  compiler: BeamCompiler,
) -> Result(Nil, Snag) {
  use _ <- result.try(
    simplifile.create_directory_all(config.build_dir)
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Creating " <> config.build_dir),
  )

  let otp_apps =
    list.fold(dependencies, dict.new(), fn(acc, p) {
      dict.insert(acc, p.name, p.otp_app)
    })

  let state =
    LoopState(
      target:,
      compiler:,
      otp_apps:,
      remaining: dependencies,
      in_flight: None,
      pending: queue.new(),
    )

  loop(state)
}

// Drives the pipeline until all packages are compiled and the beam compiler
// has confirmed all modules.
fn loop(state: LoopState) -> Result(Nil, Snag) {
  use state <- result.try(maybe_start_compile(state))

  use <- bool.guard(
    when: state.in_flight == None
      && state.remaining == []
      && queue.is_empty(state.pending),
    return: Ok(Nil),
  )

  let selector = build_selector(state)
  case process.selector_receive(from: selector, within: 60_000) {
    Error(Nil) -> snag.error("Timed out waiting for compilation")

    // we either inherit or null compiler io, so this message never happens
    Ok(CompileOutput(_)) -> loop(state)

    Ok(CompileFinished(0)) ->
      case state.in_flight {
        Some(#(dependency, _)) ->
          result.try(on_compile_finished(state, dependency), loop)
        None -> loop(state)
      }

    Ok(CompileFinished(code)) -> {
      let name = case state.in_flight {
        Some(#(dependency, _)) -> dependency.name
        None -> "<unknown>"
      }

      snag.error("exited with code " <> int.to_string(code))
      |> snag.context("Compiling " <> name)
    }

    Ok(BeamMsg(msg)) -> {
      case beam_compiler.handle_msg(state.compiler, msg) {
        beam_compiler.Exited(code) ->
          snag.error(
            "Beam compiler exited with code "
            <> int.to_string(code)
            <> " before finishing",
          )
        beam_compiler.Running(compiler:, compiled:, failed: []) -> {
          let pending = drain_queue(state.pending, list.length(compiled))
          loop(LoopState(..state, compiler:, pending:))
        }

        beam_compiler.Running(failed:, ..) -> {
          snag.error("Failed to compile: " <> string.join(failed, ", "))
        }
      }
    }
  }
}

// Starts the next compile if the in-flight slot is free.
// Rebar3/Mix packages wait for the pending queue to drain first —
// they need all .beam files from previous Gleam packages to be present.
fn maybe_start_compile(state: LoopState) -> Result(LoopState, Snag) {
  case state.in_flight, state.remaining {
    None, [dep, ..rest] ->
      case dep, queue.is_empty(state.pending) {
        // we can send more
        Gleam(..), _ | Rebar3(..), True | Mix(..), True -> {
          use proc <- result.try(spawn(dep, state.target))
          Ok(LoopState(..state, in_flight: Some(#(dep, proc)), remaining: rest))
        }
        _, _ -> Ok(state)
      }
    _, _ -> Ok(state)
  }
}

fn build_selector(state: LoopState) -> process.Selector(Msg) {
  let selector =
    process.new_selector()
    |> beam_compiler.select(state.compiler)
    |> process.map_selector(BeamMsg)

  case state.in_flight {
    None -> selector
    Some(#(_, proc)) ->
      stdio.select(selector, proc, CompileOutput, CompileFinished)
  }
}

// Drains completed packages from the front of the queue as beam compiler
// responses arrive, printing a log line for each finished package.
fn drain_queue(
  queue: Queue(#(String, Int)),
  compiled: Int,
) -> Queue(#(String, Int)) {
  use <- bool.guard(when: compiled <= 0, return: queue)

  case queue.pop_front(queue) {
    Ok(#(#(name, count), queue)) if count > compiled -> {
      queue.push_front(queue, #(name, count - compiled))
    }

    Ok(#(#(name, count), queue)) -> {
      io.println(ansi.pink("   Compiled ") <> name)
      drain_queue(queue, compiled - count)
    }

    Error(Nil) -> queue
  }
}

// Called when a package's compile process exits successfully.
// Forwards .erl artefacts to the beam compiler and adds to the pending queue.
fn on_compile_finished(
  state: LoopState,
  project: Project,
) -> Result(LoopState, Snag) {
  case project {
    Gleam(name:, dependencies:, extra_applications:, ..) -> {
      let out = filepath.join(config.build_dir, name)
      let ebin = filepath.join(out, "ebin")
      let artefacts = collect_artefacts(project, out)
      let modules =
        list.map(artefacts, fn(src) {
          filepath.strip_extension(filepath.base_name(src))
        })
      let applications =
        list.flatten([
          ["kernel", "stdlib"],
          extra_applications,
          list.map(dependencies, fn(dep) {
            dict.get(state.otp_apps, dep) |> result.unwrap(dep)
          }),
        ])
        |> list.unique
      let app =
        app_file.AppFile(
          name: project.otp_app,
          version: project.version,
          description: "",
          modules:,
          applications:,
          start_module: project.application_start_module,
        )
      use _ <- result.try(
        app_file.write(app, filepath.join(ebin, project.otp_app <> ".app"))
        |> snag.context("Writing .app file for " <> name),
      )
      use _ <- result.try(
        list.try_each(artefacts, fn(src) {
          beam_compiler.compile(state.compiler, ebin, src)
          |> snag.map_error(child_process.describe_write_error)
          |> snag.context("Sending " <> src)
        })
        |> snag.context("Sending files for " <> name <> " to the BEAM compiler"),
      )

      let pending =
        queue.push_back(state.pending, #(name, list.length(artefacts)))
      Ok(LoopState(..state, in_flight: None, pending:))
    }

    Mix(..) | Rebar3(..) -> {
      io.println(ansi.pink("   Compiled ") <> project.name)
      Ok(LoopState(..state, in_flight: None))
    }
  }
}

fn collect_artefacts(project: Project, out: String) -> List(String) {
  let artefacts_dir = filepath.join(out, "_gleam_artefacts")
  case simplifile.get_files(artefacts_dir) {
    Error(_) -> []
    Ok(files) -> list.filter(files, is_artefact(project.src, _))
  }
}

fn is_artefact(src, path) {
  let base_name = filepath.base_name(path)
  case base_name, filepath.extension(base_name) {
    "gleam@@" <> _, Ok("erl") -> False
    _, Ok("erl") | _, Ok("ex") ->
      !is_test_artefact(src, filepath.strip_extension(base_name))
    _, _ -> False
  }
}

// Returns True if the .erl artefact came from test/ rather than src/.
fn is_test_artefact(package_src: String, module_name: String) -> Bool {
  let gleam_path = string.replace(module_name, "@", "/") <> ".gleam"
  let test_path = filepath.join(package_src, filepath.join("test", gleam_path))
  simplifile.is_file(test_path) |> result.unwrap(False)
}

fn spawn(project: Project, target: InstalledTarget) -> Result(Process, Snag) {
  use _ <- result.try(
    simplifile.create_directory_all(
      filepath.join(config.build_dir, project.name)
      |> filepath.join("ebin"),
    )
    |> snag.map_error(simplifile.describe_error)
    |> snag.context("Creating ebin directory for " <> project.name),
  )
  case project {
    Gleam(..) -> spawn_gleam(project)
    Rebar3(..) -> spawn_rebar3(project, target)
    Mix(..) -> spawn_mix(project, target)
  }
}

fn spawn_gleam(project: Project) -> Result(Process, Snag) {
  let out = filepath.join(config.build_dir, project.name)
  child_process.from_name("gleam")
  |> child_process.arg("compile-package")
  |> child_process.arg("--no-beam")
  |> child_process.arg2("--target", "erlang")
  |> child_process.arg2("--package", project.src)
  |> child_process.arg2("--out", out)
  |> child_process.arg2("--lib", config.build_dir)
  |> child_process.spawn_raw(package_stdio(project))
  |> snag.map_error(child_process.describe_start_error)
  |> snag.context("Could not start compile for " <> project.name)
}

fn spawn_rebar3(
  project: Project,
  target: InstalledTarget,
) -> Result(Process, Snag) {
  // project.src is always build/packages/<name>, so ../../../ reaches the entry package.
  let out =
    "../../.." |> filepath.join(config.build_dir) |> filepath.join(project.name)
  let ebin_glob =
    "../../../" |> filepath.join(config.build_dir) |> filepath.join("/*/ebin")

  child_process.from_file(target.runtime_binary)
  |> child_process.arg("--")
  |> child_process.arg2("-root", target.otp_directory)
  |> child_process.arg2("-bindir", target.otp_directory)
  |> child_process.arg2("-home", directories.home_dir() |> result.unwrap("/"))
  |> child_process.arg2("-boot", filepath.join(target.otp_directory, "start"))
  |> child_process.arg("-noshell")
  |> child_process.args(["-s", "rebar3", "main"])
  |> child_process.arg("-extra")
  |> child_process.arg2("bare", "compile")
  |> child_process.arg2("--paths", ebin_glob)
  |> child_process.cwd(project.src)
  |> child_process.env("REBAR_BARE_COMPILER_OUTPUT_DIR", out)
  |> child_process.env("REBAR_PROFILE", "prod")
  |> child_process.env("REBAR_SKIP_PROJECT_PLUGINS", "true")
  |> child_process.spawn_raw(package_stdio(project))
  |> snag.map_error(child_process.describe_start_error)
  |> snag.context("Could not start compile for " <> project.name)
}

fn spawn_mix(
  project: Project,
  target: InstalledTarget,
) -> Result(Process, Snag) {
  let out =
    "../../../"
    |> filepath.join(config.build_dir)
    |> filepath.join(project.name)

  child_process.from_file(target.runtime_binary)
  |> child_process.arg("--")
  |> child_process.arg2("-root", target.otp_directory)
  |> child_process.arg2("-bindir", target.otp_directory)
  |> child_process.arg2("-home", directories.home_dir() |> result.unwrap("/"))
  |> child_process.arg2("-boot", filepath.join(target.otp_directory, "start"))
  |> child_process.arg("-noshell")
  |> child_process.arg2(
    "-elixir_root",
    filepath.join(target.otp_directory, "lib"),
  )
  |> child_process.args(["-s", "elixir", "start_cli"])
  |> child_process.args(["-elixir", "ansi_enabled", "true"])
  |> child_process.arg("-extra")
  |> child_process.arg("--")
  |> child_process.arg("compile")
  |> child_process.arg("--no-deps-check")
  |> child_process.arg("--no-load-deps")
  |> child_process.arg("--no-protocol-consolidation")
  |> child_process.cwd(project.src)
  |> child_process.env("MIX_BUILD_PATH", out)
  |> child_process.env("MIX_ENV", "prod")
  |> child_process.env("MIX_QUIET", "1")
  |> child_process.spawn_raw(package_stdio(project))
  |> snag.map_error(child_process.describe_start_error)
  |> snag.context("Could not start compile for " <> project.name)
}

fn package_stdio(project: Project) {
  // Show errors for the main project (src = "."); suppress output for deps.
  case project {
    Gleam(src: ".", ..) | Rebar3(..) | Mix(..) -> stdio.inherit()
    _ -> stdio.null()
  }
}
