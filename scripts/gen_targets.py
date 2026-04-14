#!/usr/bin/env python3
"""
Dev script to generate the targets array in src/gleepack/target.gleam.
Reads hashes from the GitHub releases API `digest` field — no downloads needed.

Usage:
    python3 scripts/gen_targets.py               # all releases
    python3 scripts/gen_targets.py --tag OTP-28.4.2
"""

import json
import re
import sys
import urllib.request
from typing import Optional

REPO = "yoshi-monster/gleepack"
API_BASE = "https://api.github.com"

ARCH_MAP = {
    "aarch64": "platform.Arm64",
    "amd64": "platform.X64",
}

OS_MAP = {
    "linux": "platform.Linux",
    "macos": "platform.Darwin",
    "windows": "platform.Win32",
}

ASSET_RE = re.compile(r"^gleepack-(\w+)-(linux|macos|windows)-otp-(.+)\.zip$")


def fetch_releases(tag: Optional[str]) -> list[dict]:
    if tag:
        url = f"{API_BASE}/repos/{REPO}/releases/tags/{tag}"
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req) as r:
            return [json.load(r)]
    else:
        url = f"{API_BASE}/repos/{REPO}/releases"
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req) as r:
            return json.load(r)


def targets_for_release(release: dict) -> list[tuple]:
    otp_version = release["tag_name"].removeprefix("OTP-")
    assets = {a["name"]: a for a in release["assets"]}

    otp_zip = f"otp-{otp_version}.zip"
    if otp_zip not in assets:
        print(f"  WARNING: {otp_zip} not found, skipping release", file=sys.stderr)
        return []

    otp_asset = assets[otp_zip]
    otp_link = otp_asset["browser_download_url"]
    otp_hash = otp_asset["digest"]

    targets = []
    for name in sorted(assets):
        m = ASSET_RE.match(name)
        if not m:
            continue
        arch_str, os_str, version = m.groups()
        arch = ARCH_MAP.get(arch_str)
        os = OS_MAP.get(os_str)
        if not arch or not os:
            print(f"  skipping unknown arch/os in: {name}", file=sys.stderr)
            continue
        asset = assets[name]
        targets.append((arch, os, version, asset["browser_download_url"], asset["digest"], otp_link, otp_hash))

    return targets


def main() -> None:
    tag = None
    if "--tag" in sys.argv:
        idx = sys.argv.index("--tag")
        tag = sys.argv[idx + 1]

    releases = fetch_releases(tag)
    all_targets = []
    for release in releases:
        all_targets.extend(targets_for_release(release))

    print("pub const targets = [")
    for arch, os, version, runtime_link, runtime_hash, otp_link, otp_hash in all_targets:
        print(f"  Target(")
        print(f"    arch: {arch},")
        print(f"    os: {os},")
        print(f'    otp_version: "{version}",')
        print(f"    extra: None,")
        print(f'    runtime_link: "{runtime_link}",')
        print(f'    runtime_hash: "{runtime_hash}",')
        print(f'    otp_link: "{otp_link}",')
        print(f'    otp_hash: "{otp_hash}",')
        print(f"  ),")
    print("]")


if __name__ == "__main__":
    main()
