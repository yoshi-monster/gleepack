/// Tests for reading and writing OTP application resource (.app) files.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleepack/app_file

// -- parse tests --

const minimal_app = "{application, my_app, [{vsn, \"1.0.0\"}, {modules, []}, {applications, [kernel, stdlib]}, {description, \"\"}]}."

const full_app = "{application, my_app, [
  {description, \"My application\"},
  {vsn, \"2.3.0\"},
  {modules, [my_app, 'my_app@sub']},
  {registered, []},
  {applications, [kernel, stdlib, gleam_stdlib]},
  {mod, {my_app, []}}
]}."

const app_with_module_entry = "{application, my_app, [
  {vsn, \"1.0.0\"},
  {modules, []},
  {applications, [kernel, stdlib]},
  {description, \"\"},
  {mod, {'my_app@cli', []}}
]}."

pub fn parse_extracts_name_test() {
  let assert Ok(app) = app_file.parse(minimal_app)
  assert app.name == "my_app"
}

pub fn parse_extracts_version_test() {
  let assert Ok(app) = app_file.parse(minimal_app)
  assert app.version == "1.0.0"
}

pub fn parse_extracts_applications_test() {
  let assert Ok(app) = app_file.parse(minimal_app)
  assert list.contains(app.applications, "kernel")
  assert list.contains(app.applications, "stdlib")
}

pub fn parse_extracts_modules_test() {
  let assert Ok(app) = app_file.parse(full_app)
  assert list.contains(app.modules, "my_app")
  assert list.contains(app.modules, "my_app@sub")
}

pub fn parse_extracts_description_test() {
  let assert Ok(app) = app_file.parse(full_app)
  assert app.description == "My application"
}

pub fn parse_extracts_mod_none_test() {
  let assert Ok(app) = app_file.parse(minimal_app)
  assert app.start_module == None
}

pub fn parse_extracts_mod_some_test() {
  let assert Ok(app) = app_file.parse(app_with_module_entry)
  assert app.start_module == Some("my_app@cli")
}

pub fn parse_error_on_invalid_content_test() {
  assert app_file.parse("not valid erlang") |> is_error
}

pub fn parse_error_on_wrong_tuple_test() {
  assert app_file.parse("{not_application, foo, []}.") |> is_error
}

// -- to_string / round-trip tests --

pub fn to_string_contains_application_keyword_test() {
  let app =
    app_file.AppFile(
      name: "my_app",
      version: "1.0.0",
      description: "",
      modules: [],
      applications: ["kernel", "stdlib"],
      start_module: None,
    )
  let s = app_file.to_string(app)
  assert string.contains(s, "application")
  assert string.contains(s, "my_app")
}

pub fn to_string_round_trips_test() {
  let app =
    app_file.AppFile(
      name: "my_app",
      version: "2.3.0",
      description: "Test app",
      modules: ["my_app", "my_app@sub"],
      applications: ["kernel", "stdlib", "gleam_stdlib"],
      start_module: None,
    )
  let assert Ok(parsed) = app |> app_file.to_string |> app_file.parse

  assert parsed.name == "my_app"
  assert parsed.version == "2.3.0"
  assert parsed.description == "Test app"
  assert list.contains(parsed.modules, "my_app")
  assert list.contains(parsed.modules, "my_app@sub")
  assert list.contains(parsed.applications, "kernel")
  assert list.contains(parsed.applications, "gleam_stdlib")
}

pub fn to_string_round_trips_with_start_module_test() {
  let app =
    app_file.AppFile(
      name: "my_app",
      version: "1.0.0",
      description: "",
      modules: [],
      applications: ["kernel", "stdlib"],
      start_module: Some("my_app@cli"),
    )
  let assert Ok(parsed) = app |> app_file.to_string |> app_file.parse
  assert parsed.start_module == Some("my_app@cli")
}

pub fn to_string_contains_at_atom_test() {
  let app =
    app_file.AppFile(
      name: "my_app",
      version: "1.0.0",
      description: "",
      modules: ["my_app@sub"],
      applications: ["kernel"],
      start_module: None,
    )
  // Atoms containing @ appear in the output and round-trip cleanly
  assert app_file.to_string(app) |> string.contains("my_app@sub")
}

// -- helpers --

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
