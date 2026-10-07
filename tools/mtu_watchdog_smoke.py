#!/usr/bin/env python3
"""Reject-only helper smoke checks. Never obtains authorization or changes MTU."""
import json
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: mtu_watchdog_smoke.py /path/to/LekuoMTUWatchdog")
    helper = sys.argv[1]
    cases = [
        ("unknown argument", ["--unknown"], b""),
        ("empty input", [], b""),
        ("truncated authorization fixture", [], b"\x00"),
        ("invalid authorization fixture", [], b"\x00" * 32 + b"{}\n"),
    ]
    for name, arguments, fixture in cases:
        result = subprocess.run([helper, *arguments], input=fixture, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=3, check=False)
        lines = result.stdout.splitlines()
        if len(lines) != 1:
            raise AssertionError(f"{name}: expected one terminal error reply")
        reply = json.loads(lines[0])
        if reply.get("event") != "error" or not reply.get("message"):
            raise AssertionError(f"{name}: helper did not fail closed")
        if "originalMTU" in reply or "requestedMTU" in reply:
            raise AssertionError(f"{name}: helper reached a transaction unexpectedly")
    print("MTU helper reject-only smoke checks passed; all subprocesses exited and were reaped.")


if __name__ == "__main__":
    main()
