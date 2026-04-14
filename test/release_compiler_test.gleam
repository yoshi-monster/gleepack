/// Tests for the release compiler.
import filepath
import gleam/list
import gleam/option.{None}
import gleam/string
import gleepack/app_file
import gleepack/config
import gleepack/project
import gleepack/release_compiler
import simplifile

fn make_dep(name: String, otp_app: String, src: String) -> project.Project {
  project.Gleam(
    name:,
    version: "1.0.0",
    otp_app:,
    dependencies: [],
    is_dev: False,
    src:,
    is_local: False,
    dev_dependencies: [],
    target: None,
    extra_applications: [],
    application_start_module: None,
    output: None,
    module: None,
    targets: [],
    extra_emu_args: None,
  )
}

// -- discover_otp_apps tests --

pub fn discover_otp_apps_always_includes_kernel_stdlib_test() {
  let otp_dir = filepath.join(config.build_dir, "_test_disc_ks")
  let assert Ok(Nil) = simplifile.create_directory_all(otp_dir)

  let assert Ok(apps) = release_compiler.discover_otp_apps([], otp_dir)
  assert list.contains(apps, "kernel")
  assert list.contains(apps, "stdlib")

  let _ = simplifile.delete(otp_dir)
}

fn write_app_file(
  ebin: String,
  name: String,
  applications: List(String),
) -> Nil {
  let app =
    app_file.AppFile(
      name:,
      version: "1.0.0",
      description: "",
      modules: [],
      applications:,
      start_module: None,
    )
  let assert Ok(Nil) =
    simplifile.write(
      filepath.join(ebin, name <> ".app"),
      app_file.to_string(app),
    )
  Nil
}

pub fn discover_otp_apps_reads_applications_from_app_files_test() {
  let dep_name = "_test_disc_a"
  let ebin = filepath.join(config.build_dir, dep_name) |> filepath.join("ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(ebin)
  write_app_file(ebin, dep_name, ["kernel", "stdlib"])

  let otp_dir = filepath.join(config.build_dir, "_test_disc_otp_a")
  let kernel_ebin = filepath.join(otp_dir, "lib/kernel/ebin")
  let stdlib_ebin = filepath.join(otp_dir, "lib/stdlib/ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(kernel_ebin)
  let assert Ok(Nil) = simplifile.create_directory_all(stdlib_ebin)
  write_app_file(kernel_ebin, "kernel", [])
  write_app_file(stdlib_ebin, "stdlib", [])

  let dep = make_dep(dep_name, dep_name, ".")

  let assert Ok(apps) = release_compiler.discover_otp_apps([dep], otp_dir)
  assert list.contains(apps, "kernel")
  assert list.contains(apps, "stdlib")

  let _ = simplifile.delete(filepath.join(config.build_dir, dep_name))
  let _ = simplifile.delete(otp_dir)
}

pub fn discover_otp_apps_collects_transitively_test() {
  // dep -> kernel -> stdlib (kernel's .app lists stdlib)
  let dep_name = "_test_disc_b"
  let ebin = filepath.join(config.build_dir, dep_name) |> filepath.join("ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(ebin)
  write_app_file(ebin, dep_name, ["kernel"])

  let otp_dir = filepath.join(config.build_dir, "_test_disc_otp_b")
  let kernel_ebin = filepath.join(otp_dir, "lib/kernel/ebin")
  let stdlib_ebin = filepath.join(otp_dir, "lib/stdlib/ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(kernel_ebin)
  let assert Ok(Nil) = simplifile.create_directory_all(stdlib_ebin)
  write_app_file(kernel_ebin, "kernel", ["stdlib"])
  write_app_file(stdlib_ebin, "stdlib", [])

  let dep = make_dep(dep_name, dep_name, ".")

  let assert Ok(apps) = release_compiler.discover_otp_apps([dep], otp_dir)
  assert list.contains(apps, "kernel")
  assert list.contains(apps, "stdlib")

  let _ = simplifile.delete(filepath.join(config.build_dir, dep_name))
  let _ = simplifile.delete(otp_dir)
}

pub fn discover_otp_apps_excludes_project_deps_test() {
  let dep_a = "_test_disc_c_a"
  let dep_b = "_test_disc_c_b"
  let ebin_a = filepath.join(config.build_dir, dep_a) |> filepath.join("ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(ebin_a)
  // dep_a lists dep_b and kernel in applications
  write_app_file(ebin_a, dep_a, [dep_b, "kernel"])

  let otp_dir = filepath.join(config.build_dir, "_test_disc_otp_c")
  let kernel_ebin = filepath.join(otp_dir, "lib/kernel/ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(kernel_ebin)
  write_app_file(kernel_ebin, "kernel", [])

  let assert Ok(apps) =
    release_compiler.discover_otp_apps(
      [make_dep(dep_a, dep_a, "."), make_dep(dep_b, dep_b, ".")],
      otp_dir,
    )

  // dep_b is a project dep and must not appear as an OTP app
  assert !list.contains(apps, dep_b)
  assert list.contains(apps, "kernel")

  let _ = simplifile.delete(filepath.join(config.build_dir, dep_a))
  let _ = simplifile.delete(otp_dir)
}

pub fn discover_otp_apps_deduplicates_test() {
  // Two deps both list kernel
  let dep_a = "_test_disc_d_a"
  let dep_b = "_test_disc_d_b"
  let ebin_a = filepath.join(config.build_dir, dep_a) |> filepath.join("ebin")
  let ebin_b = filepath.join(config.build_dir, dep_b) |> filepath.join("ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(ebin_a)
  let assert Ok(Nil) = simplifile.create_directory_all(ebin_b)
  write_app_file(ebin_a, dep_a, ["kernel"])
  write_app_file(ebin_b, dep_b, ["kernel"])

  let otp_dir = filepath.join(config.build_dir, "_test_disc_otp_d")
  let kernel_ebin = filepath.join(otp_dir, "lib/kernel/ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(kernel_ebin)
  write_app_file(kernel_ebin, "kernel", [])

  let assert Ok(apps) =
    release_compiler.discover_otp_apps(
      [make_dep(dep_a, dep_a, "."), make_dep(dep_b, dep_b, ".")],
      otp_dir,
    )

  let kernel_count = list.filter(apps, fn(a) { a == "kernel" }) |> list.length
  assert kernel_count == 1

  let _ = simplifile.delete(filepath.join(config.build_dir, dep_a))
  let _ = simplifile.delete(filepath.join(config.build_dir, dep_b))
  let _ = simplifile.delete(otp_dir)
}

// -- collect_dependency_files tests --

pub fn collect_dependency_files_finds_beam_and_app_test() {
  let dir = filepath.join(config.build_dir, "_test_dep_a")
  let ebin = filepath.join(dir, "ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(ebin)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(ebin, "mod_a.beam"), <<"beam_a":utf8>>)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(ebin, "_test_dep_a.app"), <<"app":utf8>>)

  let dep =
    project.Gleam(
      name: "_test_dep_a",
      version: "1.0.0",
      otp_app: "_test_dep_a",
      dependencies: [],
      is_dev: False,
      src: "build/packages/_test_dep_a",
      is_local: False,
      dev_dependencies: [],
      target: None,
      extra_applications: [],
      application_start_module: None,
      output: None,
      module: None,
      targets: [],
      extra_emu_args: None,
    )

  let assert Ok(files) = release_compiler.collect_dependency_files([dep])
  let paths = list.map(files, fn(f) { f.0 })

  assert list.contains(paths, "lib/_test_dep_a/ebin/mod_a.beam")
  assert list.contains(paths, "lib/_test_dep_a/ebin/_test_dep_a.app")

  let _ = simplifile.delete(dir)
}

pub fn collect_dependency_files_skips_gleam_internal_modules_test() {
  let dir = filepath.join(config.build_dir, "_test_dep_b")
  let ebin = filepath.join(dir, "ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(ebin)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(ebin, "gleam@@compile.beam"), <<
      "internal":utf8,
    >>)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(ebin, "real_mod.beam"), <<"real":utf8>>)

  let dep =
    project.Gleam(
      name: "_test_dep_b",
      version: "1.0.0",
      otp_app: "_test_dep_b",
      dependencies: [],
      is_dev: False,
      src: "build/packages/_test_dep_b",
      is_local: False,
      dev_dependencies: [],
      target: None,
      extra_applications: [],
      application_start_module: None,
      output: None,
      module: None,
      targets: [],
      extra_emu_args: None,
    )

  let assert Ok(files) = release_compiler.collect_dependency_files([dep])
  let paths = list.map(files, fn(f) { f.0 })

  assert list.contains(paths, "lib/_test_dep_b/ebin/real_mod.beam")
  assert !list.contains(paths, "lib/_test_dep_b/ebin/gleam@@compile.beam")

  let _ = simplifile.delete(dir)
}

pub fn collect_dependency_files_includes_priv_test() {
  // ebin
  let dir = filepath.join(config.build_dir, "_test_dep_c")
  let ebin = filepath.join(dir, "ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(ebin)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(ebin, "mod.beam"), <<"b":utf8>>)

  // priv (lives in the source directory, not build dir)
  let src = filepath.join(config.build_dir, "_test_dep_c_src")
  let priv = filepath.join(src, "priv/static")
  let assert Ok(Nil) = simplifile.create_directory_all(priv)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(priv, "index.html"), <<"<html>":utf8>>)

  let dep =
    project.Gleam(
      name: "_test_dep_c",
      version: "1.0.0",
      otp_app: "_test_dep_c",
      dependencies: [],
      is_dev: False,
      src: src,
      is_local: False,
      dev_dependencies: [],
      target: None,
      extra_applications: [],
      application_start_module: None,
      output: None,
      module: None,
      targets: [],
      extra_emu_args: None,
    )

  let assert Ok(files) = release_compiler.collect_dependency_files([dep])
  let paths = list.map(files, fn(f) { f.0 })

  assert list.contains(paths, "lib/_test_dep_c/ebin/mod.beam")
  assert list.any(paths, fn(p) { string.contains(p, "priv") })
  assert list.any(paths, fn(p) { string.contains(p, "index.html") })

  let _ = simplifile.delete(dir)
  let _ = simplifile.delete(src)
}

// -- collect_otp_apps tests --

pub fn collect_otp_apps_finds_beam_and_app_test() {
  let otp_dir = filepath.join(config.build_dir, "_test_otp")
  let kernel_ebin = filepath.join(otp_dir, "lib/kernel/ebin")
  let assert Ok(Nil) = simplifile.create_directory_all(kernel_ebin)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(kernel_ebin, "kernel.beam"), <<
      "kb":utf8,
    >>)
  let assert Ok(Nil) =
    simplifile.write_bits(filepath.join(kernel_ebin, "kernel.app"), <<
      "ka":utf8,
    >>)

  let assert Ok(files) = release_compiler.collect_otp_apps(["kernel"], otp_dir)
  let paths = list.map(files, fn(f) { f.0 })

  assert list.contains(paths, "lib/kernel/ebin/kernel.beam")
  assert list.contains(paths, "lib/kernel/ebin/kernel.app")

  let _ = simplifile.delete(otp_dir)
}

pub fn collect_otp_apps_skips_missing_app_test() {
  let otp_dir = filepath.join(config.build_dir, "_test_otp_missing")
  let assert Ok(Nil) = simplifile.create_directory_all(otp_dir)

  let assert Ok(files) =
    release_compiler.collect_otp_apps(["nonexistent"], otp_dir)
  assert files == []

  let _ = simplifile.delete(otp_dir)
}

