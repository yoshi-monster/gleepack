# gleepack

Pack a Gleam application into a single, self-contained executable. No Erlang
installation required on the target machine.

## What it does

`gleepack build` takes your Gleam project and produces a standalone binary that
you can ship directly. The binary contains:

- A full, patched version of the Erlang VM (BEAM)
- Your compiled application code and files
- All OTP libraries and other dependencies

Running the binary starts the VM and launches your application. There is nothing
to install on the target machine.

The main use case is for building simple-ish CLIs, TUIs, and dev tools
targeting the Erlang backend, without requiring the user to install Erlang too.

It is not suitable for distributing servers and other long-running software.
Please use a full OTP release or a gleam erlang-shipment for this.

## Installation

Install `gleepack` as a Gleam dev dependency in your app:

```toml
[dev_dependencies]
gleepack = { git = "git@github.com:yoshi-monster/gleepack.git", ref = "main" }
```

## Usage

### Build your project

From inside a Gleam project:

```sh
gleam run -m gleepack build
```


This produces `./build/<project-name>` by default. On the first run, gleepack
downloads the runtime and OTP toolchain for your current platform automatically.

#### Flags

| Flag | Description |
|------|-------------|
| `--output <path>` | Write the executable to `<path>` instead of the default. |
| `--module <name>` | Call `<name>.main()` as the entry point (default: your project name). |
| `--target <slug>` | Build for a specific target. Repeat to build for multiple targets. |

#### gleam.toml configuration

Flags can also be set permanently in your `gleam.toml`:

```toml
[tools.gleepack]
output = "dist/myapp"
module = "myapp/cli"
targets = ["aarch64-macos-otp-28.4.2", "amd64-linux-otp-28.4.2"]
```

### Targets

A target identifies a CPU architecture, operating system, and OTP version.
The default target matches your current platform.

| Target slug | Platform |
|-------------|----------|
| `aarch64-macos-otp-28.4.2` | Apple Silicon macOS |
| `amd64-linux-otp-28.4.2` | x86-64 Linux |
| `aarch64-linux-otp-28.4.2` | ARM64 Linux |
| `amd64-windows-otp-28.4.2` | x86-64 Windows |

Use the `gleam run -m gleepack targets` subcommands to list, add, or remove targets.

## How it works

### 1. Compile

gleepack re-implements the Gleam build tool, invoking the Gleam compiler,
BEAM compiler, and Rebar3/Mix to build BEAM bytecode suitable for your
selected targets and all its dependencies. All `.beam` files are stripped
to minimise bundle size.

### 2. Assemble a release archive

The compiled `.beam` files, private directories, and OTP library modules
are zipped into an in-memory archive. Required applications are discovered
by reading the built `.app` files.

### 3. Stamp

The archive is appended to a patched BEAM runtime to produce a self-contained
executable. This makes a polyglot file that's at the same time an executable
_and_ a ZIP file - a magic trick that works because ZIP files work with a 
file _footer_ instead of a _header_.

### 4. The patched BEAM

The VM is patched to intercept file I/O at startup:

- On launch, the entry point detects the appended ZIP and unpacks it in memory.
- BEAM File I/O calls are intercepted andredirected to that in-memory
  file system if they point to a file inside the archive.
  All other paths pass through to the OS unchanged.

This means the final binary carries everything it needs and requires no
external Erlang or OTP installation.

## Changes and limitations

The patched BEAM differs from a standard Erlang installation in a few additional ways that are worth knowing about.

### `priv` directories are read-only

Files inside your application's `priv` directory are stored in the in-memory
archive. They can be read normally via `code:priv_dir/1` and standard file
APIs, but any attempt to write to those paths will fail. Write to a
user-writable location such as a temp directory or the user's home directory
instead.

### No NIF extensions

Native Implemented Functions (NIFs) are shared libraries loaded at runtime
from disk. There are some tricks that would allow me to load them, but
they would require deeper changes to how NIFs are built - more specifically,
I would have to ship a C cross-compiler with a custom linker. This is a huge
task that I might tackle at a later time.

In general, the recommendation in Gleam is to avoid NIFs as they can break
the guarantees of the VM. We have so far identified 2 major use cases for
NIFs. I would like to first explore which are actually needed in practice,
and whether a custom build that includes them would also solve the problem.

Built-in NIFs (like `crypto` or `asn1`) are bundled within the executable
and work directly as long as the application is listed as a dependency.

### `inet_gethost` is removed

OTP normally resolves hostnames via a helper port program (`inet_gethost`).
The patched BEAM removes this helper and replaces it with direct
`gethostbyname` calls.

### `erl_child_spawn` is removed

Port programs and spawned OS processes are managed through `erl_child_spawn`
on Unix systems, another OTP helper binary. Gleepack replaces this program
with direct `posix_spawn` calls.

## Contributing

gleepack is written in Gleam with a small amount of C for the BEAM patches.

### Prerequisites

- Gleam
- Erlang/OTP
- A C compiler (ideally clang)
- macOS or Linux

### Development workflow

```sh
# Build the CLI
make

# Build and install the patched OTP runtime (takes a while on first run)
make assemble

# Run the test application
make test-release
make test-run
```

The workflow right now is a bit rough since it's only been me working on it and i didn't super mind the friction until things were ready. But it can definitely be improved a lot! Please reach out to me on Discord or make an issue if you have questions!
