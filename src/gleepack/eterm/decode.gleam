/// Decoders for Erlang terms, plus a parser for term source strings.
import gleam/dynamic/decode.{type Dynamic}
import gleam/erlang/atom
import gleam/option.{type Option}
import gleepack/eterm/encode

pub type Term =
  encode.Term

pub type DecodeError =
  decode.DecodeError

pub type Decoder(a) =
  decode.Decoder(a)

// -- Primitive decoders ------------------------------------------------------

pub fn success(a) {
  decode.success(a)
}

/// Decode an Erlang integer.
pub fn int() -> Decoder(Int) {
  decode.int
}

/// Decode an Erlang float.
pub fn float() -> Decoder(Float) {
  decode.float
}

/// Decode an Erlang atom as a `String`.
pub fn atom() -> Decoder(String) {
  atom.decoder() |> decode.map(atom.to_string)
}

/// Decode an Erlang charlist as a `String`.
pub fn string() -> Decoder(String) {
  decode.new_primitive_decoder("Charlist", do_charlist)
}

/// Decode the element at index `i` within an Erlang tuple.
pub fn element(
  element: Int,
  decoder: Decoder(a),
  next: fn(a) -> Decoder(b),
) -> Decoder(b) {
  decode.field(element, decoder, next)
}

pub fn list(element_decoder: Decoder(a)) -> Decoder(List(a)) {
  decode.list(element_decoder)
}

/// Decode a required value from an Erlang proplist by atom key.
pub fn proplist(field: String, value_decoder: Decoder(a)) -> Decoder(a) {
  use data <- decode.new_primitive_decoder("Proplist")
  do_prop(field, value_decoder, data)
}

/// Decode an optional value from an Erlang proplist by atom key.
/// Returns `None` when the key is absent.
pub fn optional_proplist(
  field: String,
  value_decoder: Decoder(a),
) -> Decoder(Option(a)) {
  decode.one_of(proplist(field, value_decoder) |> decode.map(option.Some), [
    decode.success(option.None),
  ])
}

// -- Entry points ------------------------------------------------------------

/// Parse a single Erlang term from source syntax and decode it.
pub fn parse(
  on string: String,
  run decoder: Decoder(a),
) -> Result(a, List(DecodeError)) {
  case do_parse(string) {
    Ok(term) -> run(on: term, run: decoder)
    Error(msg) -> Error([decode.DecodeError("Term", msg, [])])
  }
}

/// Run a decoder on a `Term`.
pub fn run(
  on term: Term,
  run decoder: Decoder(a),
) -> Result(a, List(DecodeError)) {
  decode.run(to_dynamic(term), decoder)
}

// -- FFI ---------------------------------------------------------------------

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(term: Term) -> Dynamic

@external(erlang, "gleepack_eterm_ffi", "charlist")
fn do_charlist(data: Dynamic) -> Result(String, String)

@external(erlang, "gleepack_eterm_ffi", "prop")
fn do_prop(field: String, decoder: Decoder(a), data: Dynamic) -> Result(a, a)

@external(erlang, "gleepack_eterm_ffi", "parse_term")
fn do_parse(string: String) -> Result(Term, String)
