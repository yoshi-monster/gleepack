import filepath
import gleam/option.{None}
import gleepack/package_cache
import gleepack/project
import gleepack/target
import simplifile

fn build_target() -> target.Target {
  target.for_test("_package_cache_test")
}

fn package(
  name: String,
  source: project.Source,
  dependencies: List(String),
) -> project.Project {
  project.Gleam(
    source:,
    name:,
    version: "1.0.0",
    otp_app: name,
    dependencies:,
    is_dev: False,
    src: "unused",
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

fn clear(name: String) -> Nil {
  let _ = simplifile.delete(target.package_build_dir(build_target(), name))
  Nil
}

fn write_app(name: String) -> Nil {
  let ebin = target.package_ebin_dir(build_target(), name)
  let assert Ok(Nil) = simplifile.create_directory_all(ebin)
  let assert Ok(Nil) =
    simplifile.write(filepath.join(ebin, name <> ".app"), "app")
  Nil
}

pub fn cache_hit_requires_committed_key_and_app_file_test() {
  let name = "_cache_complete"
  clear(name)
  let package = package(name, project.Hex(outer_checksum: "checksum"), [])
  let cache = package_cache.new([package], build_target(), "gleam 1.14.0")

  let assert Ok(package_cache.Miss) = package_cache.check(cache, package)
  let assert Ok(Nil) = package_cache.commit(cache, name)
  let assert Ok(package_cache.Miss) = package_cache.check(cache, package)

  write_app(name)
  let assert Ok(package_cache.Hit) = package_cache.check(cache, package)
  clear(name)
}

pub fn outer_checksum_changes_cache_key_test() {
  let name = "_cache_checksum"
  clear(name)
  let first = package(name, project.Hex(outer_checksum: "first"), [])
  let first_cache = package_cache.new([first], build_target(), "gleam 1.14.0")
  write_app(name)
  let assert Ok(Nil) = package_cache.commit(first_cache, name)
  let assert Ok(package_cache.Hit) = package_cache.check(first_cache, first)

  let second = package(name, project.Hex(outer_checksum: "second"), [])
  let second_cache = package_cache.new([second], build_target(), "gleam 1.14.0")
  let assert Ok(package_cache.Miss) = package_cache.check(second_cache, second)
  clear(name)
}

pub fn dependency_key_changes_package_key_test() {
  let dependency_name = "_cache_dependency"
  let package_name = "_cache_dependent"
  clear(dependency_name)
  clear(package_name)

  let first_dependency =
    package(dependency_name, project.Hex(outer_checksum: "first"), [])
  let dependent =
    package(package_name, project.Hex(outer_checksum: "dependent"), [
      dependency_name,
    ])
  let first_cache =
    package_cache.new(
      [first_dependency, dependent],
      build_target(),
      "gleam 1.14.0",
    )
  write_app(dependency_name)
  write_app(package_name)
  let assert Ok(Nil) = package_cache.commit(first_cache, dependency_name)
  let assert Ok(Nil) = package_cache.commit(first_cache, package_name)
  let assert Ok(package_cache.Hit) = package_cache.check(first_cache, dependent)

  let second_dependency =
    package(dependency_name, project.Hex(outer_checksum: "second"), [])
  let second_cache =
    package_cache.new(
      [second_dependency, dependent],
      build_target(),
      "gleam 1.14.0",
    )
  let assert Ok(package_cache.Miss) =
    package_cache.check(second_cache, dependent)

  clear(dependency_name)
  clear(package_name)
}

pub fn local_and_git_packages_are_not_cacheable_test() {
  let name = "_cache_non_hex"
  clear(name)
  let hex = package(name, project.Hex(outer_checksum: "checksum"), [])
  let hex_cache = package_cache.new([hex], build_target(), "gleam 1.14.0")
  write_app(name)
  let assert Ok(Nil) = package_cache.commit(hex_cache, name)
  let assert Ok(package_cache.Hit) = package_cache.check(hex_cache, hex)

  let local = package(name, project.Local, [])
  let local_cache = package_cache.new([local], build_target(), "gleam 1.14.0")
  let assert Ok(package_cache.Miss) = package_cache.check(local_cache, local)

  let git = package(name, project.Git, [])
  let git_cache = package_cache.new([git], build_target(), "gleam 1.14.0")
  let assert Ok(package_cache.Miss) = package_cache.check(git_cache, git)
  clear(name)
}

pub fn non_cacheable_dependency_disables_parent_cache_test() {
  let dependency_name = "_cache_local_dependency"
  let package_name = "_cache_local_dependent"
  clear(dependency_name)
  clear(package_name)

  let dependency = package(dependency_name, project.Local, [])
  let dependent =
    package(package_name, project.Hex(outer_checksum: "dependent"), [
      dependency_name,
    ])
  let cache =
    package_cache.new([dependency, dependent], build_target(), "gleam 1.14.0")
  write_app(package_name)
  let assert Ok(Nil) = package_cache.commit(cache, package_name)
  let assert Ok(package_cache.Miss) = package_cache.check(cache, dependent)

  clear(dependency_name)
  clear(package_name)
}
