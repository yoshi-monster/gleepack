//// Selects what the release compiler should produce.

pub type Mode {
  /// Full build: bundle production dependencies only and render the entrypoint
  /// that calls `module:main/0` on startup.
  Release(module: String)

  /// Used by `run` (and a future `test`): bundle dev dependencies of the main
  /// project, include its test artefacts, and render the entrypoint.
  Debug(module: String)

  /// Used by `shell`: bundle dev dependencies and include test artefacts, but
  /// do not render an entrypoint — the caller drives the runtime directly with
  /// its own boot arguments.
  Shell
}

/// True if the mode should bundle dev dependencies and include test artefacts
/// of the main project.
pub fn includes_dev(mode: Mode) -> Bool {
  case mode {
    Release(..) -> False
    Debug(..) | Shell -> True
  }
}

/// Returns the entry module to call on startup, if any.
pub fn entrypoint(mode: Mode) -> Result(String, Nil) {
  case mode {
    Release(module:) | Debug(module:) -> Ok(module)
    Shell -> Error(Nil)
  }
}
