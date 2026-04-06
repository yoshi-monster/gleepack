import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam_community/ansi
import gleepack/config
import gleepack/target
import glint.{type Command}
import input
import snag.{type Snag}

pub const group_help = "
Manage the targets "
  <> config.app_name
  <> " can build for. A target is a combination of CPU
architecture, operating system, and OTP version. Targets must be installed
locally before you can build for them.

This is usually not necessary — "
  <> config.app_name
  <> " will automatically download and
install the right target when you run `build`.
"

pub fn available() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help("
List all targets that " <> config.app_name <> " supports. A target identifies a specific
combination of CPU architecture, operating system, and OTP version that your
application can be built for.

Use `targets add <slug>` to download and install a target.
    ")
  use _, _, _ <- glint.command()

  target.targets
  |> list.map(target.slug)
  |> list.sort(string.compare)
  |> list.each(io.println)

  Ok(Nil)
}

pub fn installed() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
List all targets that are currently installed in the local cache and ready
to build for. Only installed targets can be used with `build`.

Use `targets add <slug>` to install a new target, or `targets available` to see
what targets are supported.
    ",
  )
  use _, _, _ <- glint.command()

  case target.installed() {
    [] -> {
      io.println(ansi.dim(
        "No targets installed. Run `targets add <slug>` to install one.",
      ))
    }

    installed -> {
      installed
      |> list.map(fn(t) { target.slug(t.target) })
      |> list.sort(string.compare)
      |> list.each(io.println)
    }
  }

  Ok(Nil)
}

pub fn add() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Download and install a target into the local cache so it can be used with
`build`. The runtime binary and OTP release for the target will be fetched
and stored locally.

Run `targets available` to see all supported target slugs.
    ",
  )
  use slug <- glint.named_arg("slug")
  use named, _, _ <- glint.command()

  let slug = slug(named)
  use target <- result.try(
    target.from_string(slug)
    |> snag.replace_error(
      "Unknown target "
      <> string.inspect(slug)
      <> ". Run `targets available` to list all supported targets.",
    ),
  )

  use installed_target <- result.try(
    target.install(target) |> snag.context("Installing " <> target.slug(target)),
  )

  io.println(
    ansi.pink("  Installed") <> " " <> target.slug(installed_target.target),
  )

  Ok(Nil)
}

pub fn clean() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Remove all installed targets from the local cache.

This is not usually necessary. Run `targets installed` to see what is
currently installed.
    ",
  )
  use _, _, _ <- glint.command()

  case target.installed() {
    [] -> Ok(io.println(ansi.pink("      Clean") <> " No targets installed"))
    installed -> {
      case input.input(prompt: "Remove all installed targets? [y|N] ") {
        Ok("y") | Ok("Y") ->
          list.try_each(installed, fn(t) { target.uninstall(t.target) })
        _ -> Ok(io.println(ansi.pink("      Clean") <> " Cancelled"))
      }
    }
  }
}

pub fn remove() -> Command(Result(Nil, Snag)) {
  use <- glint.command_help(
    "
Remove an installed target from the local cache.

Run `targets installed` to see what is currently installed.
    ",
  )
  use slug <- glint.named_arg("slug")
  use named, _, _ <- glint.command()

  let slug = slug(named)
  use target <- result.try(
    target.from_string(slug)
    |> snag.replace_error(
      "Unknown target "
      <> string.inspect(slug)
      <> ". Run `targets available` to list all supported targets.",
    ),
  )

  use Nil <- result.try(
    target.uninstall(target)
    |> snag.context("Uninstalling " <> target.slug(target)),
  )

  Ok(Nil)
}
