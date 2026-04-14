/// Tests for Erlang term decoding.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleepack/eterm/decode as d
import gleepack/eterm/encode

// -- int --

pub fn int_decodes_integer_test() {
  assert d.parse(on: "42.", run: d.int()) == Ok(42)
}

pub fn int_fails_on_atom_test() {
  assert d.parse(on: "foo.", run: d.int()) |> is_error
}

// -- float --

pub fn float_decodes_float_test() {
  assert d.parse(on: "1.0.", run: d.float()) == Ok(1.0)
}

pub fn float_fails_on_integer_test() {
  assert d.parse(on: "1.", run: d.float()) |> is_error
}

// -- atom --

pub fn atom_decodes_atom_test() {
  assert d.parse(on: "kernel.", run: d.atom()) == Ok("kernel")
}

pub fn atom_decodes_at_atom_test() {
  assert d.parse(on: "my_app@sub.", run: d.atom()) == Ok("my_app@sub")
}

pub fn atom_fails_on_string_test() {
  assert d.parse(on: "\"hello\".", run: d.atom()) |> is_error
}

// -- string (charlist) --

pub fn string_decodes_charlist_test() {
  assert d.parse(on: "\"hello\".", run: d.string()) == Ok("hello")
}

pub fn string_decodes_empty_charlist_test() {
  assert d.parse(on: "\"\".", run: d.string()) == Ok("")
}

pub fn string_fails_on_atom_test() {
  assert d.parse(on: "hello.", run: d.string()) |> is_error
}

// -- element --

pub fn element_decodes_tuple_field_test() {
  let decoder = {
    use n <- d.element(1, d.int())
    decode.success(n)
  }
  assert d.parse(on: "{ok, 42}.", run: decoder) == Ok(42)
}

pub fn element_decodes_first_field_test() {
  let decoder = {
    use tag <- d.element(0, d.atom())
    decode.success(tag)
  }
  assert d.parse(on: "{error, bad}.", run: decoder) == Ok("error")
}

// -- proplist --

pub fn proplist_decodes_int_field_test() {
  assert d.parse(on: "[{count, 7}].", run: d.proplist("count", d.int())) == Ok(7)
}

pub fn proplist_decodes_atom_field_test() {
  assert d.parse(on: "[{name, kernel}].", run: d.proplist("name", d.atom()))
    == Ok("kernel")
}

pub fn proplist_decodes_string_field_test() {
  assert d.parse(on: "[{vsn, \"1.0.0\"}].", run: d.proplist("vsn", d.string()))
    == Ok("1.0.0")
}

pub fn proplist_composes_multiple_fields_test() {
  let src = "[{vsn, \"2.0.0\"}, {name, my_app}]."
  let assert Ok(vsn) = d.parse(on: src, run: d.proplist("vsn", d.string()))
  let assert Ok(name) = d.parse(on: src, run: d.proplist("name", d.atom()))
  assert vsn == "2.0.0"
  assert name == "my_app"
}

pub fn proplist_fails_on_missing_key_test() {
  assert d.parse(on: "[{vsn, \"1.0.0\"}].", run: d.proplist("modules", d.atom()))
    |> is_error
}

pub fn proplist_fails_on_wrong_type_test() {
  assert d.parse(on: "[{vsn, 42}].", run: d.proplist("vsn", d.string()))
    |> is_error
}

pub fn proplist_fails_on_non_list_test() {
  assert d.parse(on: "not_a_list.", run: d.proplist("vsn", d.string()))
    |> is_error
}

// -- optional_proplist --

pub fn optional_proplist_returns_some_when_present_test() {
  assert d.parse(
    on: "[{vsn, \"1.0\"}].",
    run: d.optional_proplist("vsn", d.string()),
  ) == Ok(Some("1.0"))
}

pub fn optional_proplist_returns_none_when_absent_test() {
  assert d.parse(
    on: "[{name, foo}].",
    run: d.optional_proplist("vsn", d.string()),
  ) == Ok(None)
}


// -- compile result tuple {Binary, [Atom]} --

pub fn compile_result_decodes_file_and_single_module_test() {
  let decoder = {
    use file <- d.element(0, decode.string)
    use modules <- d.element(1, decode.list(d.atom()))
    decode.success(#(file, modules))
  }
  assert d.parse(on: "{<<\"src/foo.erl\">>, [foo_mod]}.", run: decoder)
    == Ok(#("src/foo.erl", ["foo_mod"]))
}

pub fn compile_result_decodes_file_and_empty_modules_test() {
  let decoder = {
    use file <- d.element(0, decode.string)
    use modules <- d.element(1, decode.list(d.atom()))
    decode.success(#(file, modules))
  }
  assert d.parse(on: "{<<\"src/foo.erl\">>, []}.", run: decoder)
    == Ok(#("src/foo.erl", []))
}

pub fn compile_result_decodes_elixir_modules_test() {
  let decoder = {
    use file <- d.element(0, decode.string)
    use modules <- d.element(1, decode.list(d.atom()))
    decode.success(#(file, modules))
  }
  assert d.parse(
    on: "{<<\"src/foo.ex\">>, ['Elixir.Foo', 'Elixir.Bar']}.",
    run: decoder,
  ) == Ok(#("src/foo.ex", ["Elixir.Foo", "Elixir.Bar"]))
}

// -- parse --

pub fn parse_fails_on_invalid_syntax_test() {
  assert d.parse(on: "not valid erlang", run: d.int()) |> is_error
}

// -- run --

pub fn run_decodes_encoded_int_test() {
  assert d.run(on: encode.int(99), run: d.int()) == Ok(99)
}

pub fn run_decodes_encoded_atom_test() {
  assert d.run(on: encode.atom("stdlib"), run: d.atom()) == Ok("stdlib")
}

pub fn run_decodes_encoded_string_test() {
  assert d.run(on: encode.string("world"), run: d.string()) == Ok("world")
}

pub fn run_decodes_list_of_atoms_test() {
  let assert Ok(apps) =
    d.parse(on: "[kernel, stdlib].", run: decode.list(d.atom()))
  assert list.contains(apps, "kernel")
  assert list.contains(apps, "stdlib")
}

// -- helpers --

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
