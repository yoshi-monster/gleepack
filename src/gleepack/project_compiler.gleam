//// Drives a two-stage pipeline: compile packages to .erl (stage 1) while
//// concurrently compiling .erl to .beam via the beam compiler (stage 2).

import directories
import filepath
import gleam/bool
import gleam/deque.{type Deque as Queue} as queue
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import gleepack/app_file
import gleepack/beam_compiler.{type BeamCompiler}
import gleepack/config
import gleepack/io.{type Process}
import gleepack/mode.{type Mode}
import gleepack/project.{type Project, Gleam, Mix, Rebar3}
import gleepack/target.{type InstalledTarget}
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
    mode: Mode,
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
  mode: Mode,
  target: InstalledTarget,
  compiler: BeamCompiler,
) -> Result(Nil, Snag) {
  let otp_apps =
    list.fold(dependencies, dict.new(), fn(acc, p) {
      dict.insert(acc, p.name, p.otp_app)
    })

  let state =
    LoopState(
      target:,
      compiler:,
      mode:,
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
      |> snag.context("Compiling package " <> name)
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
// Rebar3/Mix packages wait for the pending queue to drain first -
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
      io.select_process(selector, proc, CompileOutput, CompileFinished)
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
    Gleam(name:, dependencies:, dev_dependencies:, extra_applications:, ..) -> {
      let out = filepath.join(config.build_dir, name)
      let ebin = filepath.join(out, "ebin")
      use Nil <- result.try(beam_compiler.add_path(state.compiler, ebin))
      let artefacts = collect_artefacts(project, state.mode, out)
      let modules =
        list.map(artefacts, fn(src) {
          filepath.strip_extension(filepath.base_name(src))
        })
      // In modes that bundle dev deps, surface the entry project's
      // dev_dependencies in its applications list so OTP starts them and
      // `application:priv_dir/1` etc. work for tools like lustre_dev_tools.
      let app_dependencies = case
        mode.includes_dev(state.mode) && project.src == "."
      {
        True -> list.append(dependencies, dev_dependencies)
        False -> dependencies
      }
      let applications =
        list.flatten([
          ["kernel", "stdlib"],
          extra_applications,
          list.map(app_dependencies, fn(dep) {
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
          |> snag.context("Sending " <> src)
        })
        |> snag.context("Sending files for " <> name <> " to the BEAM compiler"),
      )

      // Packages with no .erl artefacts (interface-only / pure-FFI) never get
      // a beam compiler response, so they'd stay in `pending` forever and
      // block subsequent Rebar3/Mix spawns. Print directly instead.
      let pending = case artefacts {
        [] -> {
          io.println(ansi.pink("   Compiled ") <> name)
          state.pending
        }
        _ -> queue.push_back(state.pending, #(name, list.length(artefacts)))
      }
      Ok(LoopState(..state, in_flight: None, pending:))
    }

    Mix(src:, name:, otp_app:, ..) -> {
      use Nil <- result.try(place_mix_output(src, name, otp_app))
      use Nil <- result.try(
        filepath.join(config.build_dir, name)
        |> filepath.join("ebin")
        |> beam_compiler.add_path(state.compiler, _),
      )
      io.println(ansi.pink("   Compiled ") <> name)
      Ok(LoopState(..state, in_flight: None))
    }

    Rebar3(name:, ..) -> {
      use Nil <- result.try(
        filepath.join(config.build_dir, name)
        |> filepath.join("ebin")
        |> beam_compiler.add_path(state.compiler, _),
      )
      io.println(ansi.pink("   Compiled ") <> name)
      Ok(LoopState(..state, in_flight: None))
    }
  }
}

fn collect_artefacts(
  project: Project,
  mode: Mode,
  out: String,
) -> List(String) {
  // Test artefacts (.erl compiled from test/) are kept only for the main
  // project (src = ".") when the mode bundles dev dependencies. Dependencies
  // never contribute their test modules to the release.
  let keep_tests = mode.includes_dev(mode) && project.src == "."
  let artefacts_dir = filepath.join(out, "_gleam_artefacts")
  case io.get_files_if_exists(artefacts_dir) {
    Error(_) -> []
    Ok(files) -> list.filter(files, is_artefact(project.src, keep_tests, _))
  }
}

fn is_artefact(src, keep_tests, path) {
  let base_name = filepath.base_name(path)
  case base_name, filepath.extension(base_name) {
    "gleam@@" <> _, Ok("erl") -> False
    _, Ok("erl") | _, Ok("ex") ->
      keep_tests || !is_test_artefact(src, filepath.strip_extension(base_name))
    _, _ -> False
  }
}

// Returns True if the .erl artefact came from test/ rather than src/.
fn is_test_artefact(package_src: String, module_name: String) -> Bool {
  let gleam_path = string.replace(module_name, "@", "/") <> ".gleam"
  let test_path = filepath.join(package_src, filepath.join("test", gleam_path))
  io.file_exists(test_path)
}

fn spawn(project: Project, target: InstalledTarget) -> Result(Process, Snag) {
  use _ <- result.try(case project {
    Mix(..) -> Ok(Nil)
    _ ->
      io.create_directory_all(
        filepath.join(config.build_dir, project.name)
        |> filepath.join("ebin"),
      )
  })
  case project {
    Gleam(..) -> start_gleam_compiler(project)
    Rebar3(..) -> start_rebar3_compiler(project, target)
    Mix(..) -> start_mix_compiler(project, target)
  }
}

fn start_gleam_compiler(project: Project) -> Result(Process, Snag) {
  let out = filepath.join(config.build_dir, project.name)
  io.from_name("gleam")
  |> io.arg("compile-package")
  |> io.arg("--no-beam")
  |> io.arg2("--target", "erlang")
  |> io.arg2("--package", project.src)
  |> io.arg2("--out", out)
  |> io.arg2("--lib", config.build_dir)
  |> io.spawn(output: package_output(project))
}

fn start_rebar3_compiler(
  project: Project,
  target: InstalledTarget,
) -> Result(Process, Snag) {
  let out = filepath.join(config.build_dir, project.name)
  // project.src is always build/packages/<name>, so ../../../ reaches the entry package.
  let rebar_out = "../../.." |> filepath.join(out)
  let ebin_glob =
    "../../../" |> filepath.join(config.build_dir) |> filepath.join("/*/ebin")

  use Nil <- result.try(io.copy_directory_if_exists(
    filepath.join(project.src, "include"),
    filepath.join(out, "include"),
  ))

  io.from_file(target.runtime_binary)
  |> io.arg("--")
  |> io.arg2("-root", target.otp_directory)
  |> io.arg2("-bindir", target.otp_directory)
  |> io.arg2("-home", directories.home_dir() |> result.unwrap("/"))
  |> io.arg2("-boot", filepath.join(target.otp_directory, "start"))
  |> io.arg("-noshell")
  |> io.args(["-s", "rebar3", "main"])
  |> io.arg("-extra")
  |> io.arg2("bare", "compile")
  |> io.arg2("--paths", ebin_glob)
  |> io.arg2("--outdir", rebar_out)
  |> io.cwd(project.src)
  |> io.env("REBAR_PROFILE", "prod")
  |> io.env("REBAR_SKIP_PROJECT_PLUGINS", "true")
  |> io.spawn(output: package_output(project))
}

fn start_mix_compiler(
  project: Project,
  target: InstalledTarget,
) -> Result(Process, Snag) {
  let ebin_glob =
    "../../../" |> filepath.join(config.build_dir) |> filepath.join("/*/ebin")

  io.from_file(target.runtime_binary)
  |> io.arg("--")
  |> io.arg2("-root", target.otp_directory)
  |> io.arg2("-bindir", target.otp_directory)
  |> io.arg2("-home", directories.home_dir() |> result.unwrap("/"))
  |> io.arg2("-boot", filepath.join(target.otp_directory, "start"))
  |> io.arg("-noshell")
  |> io.arg2("-elixir_root", filepath.join(target.otp_directory, "lib"))
  |> io.args(["-s", "elixir", "start_cli"])
  |> io.args(["-elixir", "ansi_enabled", "true"])
  |> io.arg("-extra")
  |> io.arg2("-pa", ebin_glob)
  |> io.args(["-S", "mix", "compile"])
  |> io.arg("--no-deps-check")
  |> io.arg("--no-load-deps")
  |> io.arg("--no-protocol-consolidation")
  |> io.cwd(project.src)
  |> io.env("MIX_BUILD_PATH", "_build/prod")
  |> io.env("MIX_ENV", "prod")
  |> io.env("MIX_QUIET", "1")
  |> io.spawn(output: package_output(project))
}

fn place_mix_output(
  src: String,
  name: String,
  otp_app: String,
) -> Result(Nil, Snag) {
  let source =
    src
    |> filepath.join("_build/prod/lib")
    |> filepath.join(otp_app)
  let destination = filepath.join(config.build_dir, name)

  io.replace_with_link_or_copy_directory(source, destination)
  |> snag.context("Placing Mix output for " <> otp_app)
}

fn package_output(project: Project) -> io.ProcessOutput {
  // Show errors for local porjects; suppress output for deps.
  case project {
    Gleam(source: project.Local, ..) | Rebar3(..) | Mix(..) -> io.Inherit
    _ -> io.Ignore
  }
}
