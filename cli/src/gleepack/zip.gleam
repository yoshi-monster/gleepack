/// A type-safe wrapper around Erlang's zip module.
///
/// Supports two use cases:
/// - Building a zip archive in memory with per-extension compression control.
/// - Extracting a zip archive to disk.

pub opaque type Builder {
  Builder(files: List(#(String, BitArray)), stored_extensions: List(String))
}

/// A handle to an open zip archive for reading. Must be closed with `close`.
pub type Handle

/// A file entry in a zip archive.
pub type Entry {
  Entry(path: String, size: Int)
}

pub type Error {
  /// The bytes could not be parsed as a zip archive.
  InvalidArchive
  /// The requested file was not found in the archive.
  FileMissing(path: String)
  /// The archive handle has already been closed.
  HandleClosed
}

/// Describe a zip error as a human-readable string.
pub fn describe_error(error: Error) -> String {
  case error {
    InvalidArchive -> "not a valid zip archive"
    FileMissing(path) -> "file not found in archive: " <> path
    HandleClosed -> "zip handle has been closed"
  }
}

/// Create a new archive builder.
pub fn new() -> Builder {
  Builder(files: [], stored_extensions: [])
}

/// Mark files with these extensions to be stored without compression.
/// All other files are compressed with deflate. Use for already-compressed
/// or binary formats such as `[".beam", ".app", ".so", ".dll"]`.
pub fn store_extensions(builder: Builder, extensions: List(String)) -> Builder {
  Builder(..builder, stored_extensions: extensions)
}

/// Add a file to the archive.
pub fn add(
  builder: Builder,
  at path: String,
  containing data: BitArray,
) -> Builder {
  Builder(..builder, files: [#(path, data), ..builder.files])
}

/// Build the archive and return it as bytes in memory.
@external(erlang, "gleepack_zip_ffi", "build_memory")
pub fn build_memory(builder: Builder) -> BitArray

/// Open a zip archive from bytes for reading.
///
/// Returns an error if the bytes are not a valid zip archive.
/// The handle must be closed with `close` when done.
@external(erlang, "gleepack_zip_ffi", "open")
pub fn open(zip: BitArray) -> Result(Handle, Error)

/// List all file entries in the archive, including their uncompressed sizes.
///
/// Returns an error if the handle has been closed.
@external(erlang, "gleepack_zip_ffi", "list_files")
pub fn list(handle: Handle) -> Result(List(Entry), Error)

/// Read a single file from the archive by path.
///
/// Returns an error if the handle has been closed or the path does not exist.
@external(erlang, "gleepack_zip_ffi", "get_file")
pub fn get(handle: Handle, path: String) -> Result(BitArray, Error)

/// Extract all files from a zip archive to a directory on disk.
///
/// Returns the list of extracted file paths on success.
@external(erlang, "gleepack_zip_ffi", "extract_to_disk")
pub fn extract_to_disk(
  zip: BitArray,
  to directory: String,
) -> Result(List(String), Error)

/// Close the archive handle.
@external(erlang, "gleepack_zip_ffi", "close")
pub fn close(handle: Handle) -> Nil
