//// Encode Gleam values as Erlang terms for use with Erlang interop.
////
//// `Term` represents a well-formed Erlang term. Use `to_string` to serialise
//// a `Term` to Erlang source syntax (e.g. for writing `.app` files).

import gleam/list

/// An Erlang term. Construct values of this type using the functions in this
/// module and serialise them with `to_string`.
pub type Term

/// Encode an `Int` as an Erlang integer term.
@external(erlang, "gleam_stdlib", "identity")
pub fn int(n: Int) -> Term

/// Encode a `Float` as an Erlang float term.
@external(erlang, "gleam_stdlib", "identity")
pub fn float(f: Float) -> Term

/// Encode a `String` as an Erlang charlist.
/// Erlang conventionally represents strings as lists of codepoints, so use
/// this when the target expects a string-typed field.
@external(erlang, "unicode", "characters_to_list")
pub fn string(s: String) -> Term

/// Encode a `String` as an Erlang atom.
/// The string is converted via `binary_to_atom` and is never garbage-collected,
/// so only use this for values drawn from a bounded set (e.g. known key names).
@external(erlang, "erlang", "binary_to_atom")
pub fn atom(a: String) -> Term

/// Encode a list of `Term`s as an Erlang tuple.
@external(erlang, "erlang", "list_to_tuple")
pub fn tuple(elements: List(Term)) -> Term

/// Encode a list of `{String, Term}` pairs as an Erlang proplist.
/// Each string key is encoded as an atom.
pub fn proplist(pairs: List(#(String, Term))) {
  from(list.map(pairs, fn(pair) { #(atom(pair.0), pair.1) }))
}

/// Encode a `List(a)` as an Erlang list, converting each element with `encode`.
pub fn list(items: List(a), encode: fn(a) -> Term) {
  from(list.map(items, encode))
}

/// Serialise a `Term` to Erlang source syntax, terminated with `.\n`.
/// Suitable for writing `.app` files and similar Erlang term files.
pub fn to_string(term: Term) -> String {
  bformat("~0p.~n", [term])
}

/// Serialise a `Term` to Erlang source syntax, terminated with `.\n`.
/// Suitable for writing `.app` files and similar Erlang term files.
pub fn to_pretty_string(term: Term) -> String {
  bformat("~p.~n", [term])
}

@external(erlang, "gleam_stdlib", "identity")
fn from(a: value) -> Term

@external(erlang, "io_lib", "bformat")
fn bformat(format: String, terms: List(Term)) -> String
