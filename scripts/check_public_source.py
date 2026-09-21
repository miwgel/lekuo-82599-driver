#!/usr/bin/env python3
"""Fail CI when tracked source contains common forms of private local data."""

from __future__ import annotations

import pathlib
import re
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {
    "", ".c", ".cc", ".cpp", ".entitlements", ".h", ".iig", ".json",
    ".md", ".pbxproj", ".plist", ".py", ".sh", ".swift", ".txt",
    ".xcconfig", ".yml", ".yaml",
}
FORBIDDEN = {
    "absolute macOS home path": re.compile(rb"/" + rb"Users/[^/\s]+/"),
    "private IPv4 address": re.compile(
        rb"(?<![0-9])(?:10\.[0-9]{1,3}(?:\.[0-9]{1,3}){2}|"
        rb"192\.168(?:\.[0-9]{1,3}){2}|"
        rb"172\.(?:1[6-9]|2[0-9]|3[01])(?:\.[0-9]{1,3}){2})(?![0-9])"
    ),
    "email address": re.compile(
        rb"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}",
        re.IGNORECASE,
    ),
}


def source_files() -> list[pathlib.Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    )
    return [ROOT / item.decode() for item in output.split(b"\0") if item]


def main() -> int:
    failures: list[str] = []
    for path in source_files():
        if path.resolve() == pathlib.Path(__file__).resolve():
            continue
        if path.suffix.lower() not in TEXT_SUFFIXES or not path.is_file():
            continue
        data = path.read_bytes()
        for label, pattern in FORBIDDEN.items():
            if pattern.search(data):
                failures.append(f"{path.relative_to(ROOT)}: {label}")

    history = subprocess.check_output(
        ["git", "log", "--all", "--format=%ae%n%ce"], cwd=ROOT, text=True
    )
    for address in filter(None, history.splitlines()):
        normalized = address.lower()
        if not (
            normalized.endswith("@users.noreply.github.com")
            or normalized == "noreply@github.com"
        ):
            failures.append("Git history contains a non-noreply author address")
            break

    if failures:
        print("Public-source privacy check failed:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("Public-source privacy check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
