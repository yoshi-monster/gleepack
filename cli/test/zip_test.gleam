/// Tests for the zip archive module.
import gleam/list
import gleepack/zip

const hello = <<"hello world":utf8>>

const goodbye = <<"goodbye world":utf8>>

// -- build / open / get -------------------------------------------------------

pub fn round_trip_get_test() {
  let bits =
    zip.new()
    |> zip.add(at: "a/hello.txt", containing: hello)
    |> zip.to_bits()

  let assert Ok(handle) = zip.open(bits)
  let assert Ok(data) = zip.get(handle, "a/hello.txt")
  zip.close(handle)
  assert data == hello
}

pub fn round_trip_multiple_files_test() {
  let bits =
    zip.new()
    |> zip.add(at: "hello.txt", containing: hello)
    |> zip.add(at: "goodbye.txt", containing: goodbye)
    |> zip.to_bits()

  let assert Ok(handle) = zip.open(bits)
  let assert Ok(a) = zip.get(handle, "hello.txt")
  let assert Ok(b) = zip.get(handle, "goodbye.txt")
  zip.close(handle)
  assert a == hello
  assert b == goodbye
}

// -- list ---------------------------------------------------------------------

pub fn list_returns_entries_test() {
  let bits =
    zip.new()
    |> zip.add(at: "hello.txt", containing: hello)
    |> zip.add(at: "goodbye.txt", containing: goodbye)
    |> zip.to_bits()

  let assert Ok(handle) = zip.open(bits)
  let assert Ok(entries) = zip.list(handle)
  zip.close(handle)

  let paths = list.map(entries, fn(e) { e.path })
  assert list.contains(paths, "hello.txt")
  assert list.contains(paths, "goodbye.txt")
}

pub fn list_entry_size_test() {
  let bits =
    zip.new()
    |> zip.add(at: "hello.txt", containing: hello)
    |> zip.to_bits()

  let assert Ok(handle) = zip.open(bits)
  let assert Ok(entries) = zip.list(handle)
  zip.close(handle)

  let assert [entry] = entries
  assert entry.path == "hello.txt"
  assert entry.size == 11
}

// -- errors -------------------------------------------------------------------

pub fn open_invalid_archive_test() {
  assert zip.open(<<"not a zip":utf8>>) == Error(zip.InvalidArchive)
}

pub fn get_missing_file_test() {
  let bits =
    zip.new()
    |> zip.add(at: "hello.txt", containing: hello)
    |> zip.to_bits()

  let assert Ok(handle) = zip.open(bits)
  let result = zip.get(handle, "does_not_exist.txt")
  zip.close(handle)
  assert result == Error(zip.FileMissing("does_not_exist.txt"))
}

pub fn get_after_close_test() {
  let bits =
    zip.new()
    |> zip.add(at: "hello.txt", containing: hello)
    |> zip.to_bits()

  let assert Ok(handle) = zip.open(bits)
  zip.close(handle)
  assert zip.get(handle, "hello.txt") == Error(zip.HandleClosed)
}

// -- store_extensions ---------------------------------------------------------

pub fn store_extensions_round_trip_test() {
  // Files with stored extensions should survive the round-trip intact.
  let bits =
    zip.new()
    |> zip.store_extensions([".beam"])
    |> zip.add(at: "mymodule.beam", containing: hello)
    |> zip.to_bits()

  let assert Ok(handle) = zip.open(bits)
  let assert Ok(data) = zip.get(handle, "mymodule.beam")
  zip.close(handle)
  assert data == hello
}
