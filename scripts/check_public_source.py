#!/usr/bin/env python3
"""Fail CI when tracked source contains common forms of private local data."""

from __future__ import annotations

import pathlib
import argparse
import re
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN = {
    "absolute macOS home path": re.compile(rb"/" + rb"Users/[^/\s]+/"),
    "private IPv4 address": re.compile(
        rb"(?<![0-9])(?:10\.[0-9]{1,3}(?:\.[0-9]{1,3}){2}|"
        rb"192\.168(?:\.[0-9]{1,3}){2}|"
        rb"172\.(?:1[6-9]|2[0-9]|3[01])(?:\.[0-9]{1,3}){2})(?![0-9])"
    ),
    "MAC address": re.compile(rb"(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}(?![0-9a-fA-F:])"),
    "link-local IPv6 address": re.compile(rb"(?i)fe80:[0-9a-f:%]+"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "GitHub credential": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})"),
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


FORBIDDEN_SUFFIXES = {".p12", ".p8", ".pfx", ".key", ".pem", ".cer", ".csr",
                      ".provisionprofile", ".mobileprovision", ".pcap", ".pcapng",
                      ".keychain", ".keychain-db"}


def findings(name: str, data: bytes) -> list[str]:
    path = pathlib.PurePosixPath(name)
    result = []
    if path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name == ".env" or path.name.startswith(".env."):
        result.append("signing material, credentials, or raw network evidence")
    # Scan bytes regardless of suffix so renamed credentials, unfamiliar source
    # languages, and readable metadata in binary assets are not silently skipped.
    for label, pattern in FORBIDDEN.items():
        for match in pattern.finditer(data):
            # Deliberately synthetic values exercise diagnostic redaction and
            # IPv6 scope validation; exceptions are confined to those fixtures.
            if name == "scripts/tests/test_control_models.swift" and label == "MAC address" and match.group() == b"02:00:" + b"00:00:00:01":
                continue
            if name == "scripts/tests/test_adapter_service.swift" and label == "link-local IPv6 address" and match.group() in {b"fe80:" + b":10%e", b"fe80:" + b":10%"}:
                continue
            if label == "email address":
                email = match.group().lower()
                if email.endswith(b"@users.noreply.github.com") or email == b"noreply@github.com":
                    continue
            result.append(label)
            break
    return result


def historical_blobs():
    # Inspect every reachable file version, including deleted files. A clean
    # working tree alone does not make existing Git history safe to publish.
    lines = subprocess.check_output(["git", "rev-list", "--objects", "--all"], cwd=ROOT).splitlines()
    objects = {}
    for line in lines:
        parts = line.split(b" ", 1)
        if len(parts) == 2:
            objects[parts[0]] = parts[1].decode("utf-8", errors="replace")
    if not objects:
        return
    process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=ROOT,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for oid, name in objects.items():
            process.stdin.write(oid + b"\n")
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3:
                raise RuntimeError("Could not inspect Git object")
            data = process.stdout.read(int(header[2]))
            if process.stdout.read(1) != b"\n":
                raise RuntimeError("Invalid Git object boundary")
            if header[1] == b"blob":
                yield name, data
    finally:
        process.stdin.close()
        process.stdout.close()
        process.wait(timeout=10)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--working-tree-only", action="store_true")
    args = parser.parse_args()
    failures: set[str] = set()
    for path in source_files():
        if path.is_file():
            for label in findings(str(path.relative_to(ROOT)), path.read_bytes()):
                failures.add(f"Working tree: {path.relative_to(ROOT)}: {label}")
    if not args.working_tree_only:
        for name, data in historical_blobs():
            for label in findings(name, data):
                failures.add(f"Git history: {name}: {label}")

    history = subprocess.check_output(
        ["git", "log", "--all", "--format=%ae%n%ce"], cwd=ROOT, text=True
    )
    for address in filter(None, history.splitlines()):
        normalized = address.lower()
        if not (normalized.endswith("@users.noreply.github.com") or normalized == "noreply@github.com"):
            failures.add("Git history contains a non-noreply author address")
            break
    commit_text = subprocess.check_output(
        ["git", "log", "--all", "--format=%an%n%cn%n%B"], cwd=ROOT
    )
    tag_text = subprocess.check_output(
        ["git", "for-each-ref", "--format=%(contents)", "refs/tags"], cwd=ROOT
    )
    for label in findings("history.txt", commit_text + tag_text):
        failures.add(f"Git commit or tag metadata: {label}")
    if failures:
        print("Public-source privacy check failed (matched values are withheld):")
        for failure in sorted(failures):
            print(f"- {failure}")
        return 1
    print("Public-source privacy check passed, including reachable Git history")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
