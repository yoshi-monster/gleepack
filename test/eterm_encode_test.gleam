/// Tests for Erlang term encoding.

import gleepack/eterm/encode

pub fn int_test() {
  assert encode.to_string(encode.int(42)) == "42.\n"
}

pub fn float_test() {
  assert encode.to_string(encode.float(1.0)) == "1.0.\n"
}

pub fn atom_test() {
  assert encode.to_string(encode.atom("kernel")) == "kernel.\n"
}

pub fn atom_with_at_sign_test() {
  assert encode.to_string(encode.atom("my_app@sub")) == "my_app@sub.\n"
}

pub fn string_encodes_as_charlist_test() {
  assert encode.to_string(encode.string("hello")) == "\"hello\".\n"
}

pub fn tuple_test() {
  let t = encode.tuple([encode.atom("application"), encode.atom("my_app")])
  assert encode.to_string(t) == "{application,my_app}.\n"
}

pub fn proplist_test() {
  let p = encode.proplist([#("vsn", encode.int(1))])
  assert encode.to_string(p) == "[{vsn,1}].\n"
}

pub fn list_test() {
  let l = encode.list([1, 2, 3], encode.int)
  assert encode.to_string(l) == "[1,2,3].\n"
}
