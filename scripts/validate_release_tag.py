#!/usr/bin/env python3
"""Validate the repository's YYYY.MM.DD release tag format."""

from __future__ import annotations

import datetime as dt
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_release_tag.py YYYY.MM.DD", file=sys.stderr)
        return 2

    tag = sys.argv[1]
    if re.fullmatch(r"\d{4}\.\d{2}\.\d{2}", tag) is None:
        print("release tags must use YYYY.MM.DD, for example 2026.01.02", file=sys.stderr)
        return 1

    try:
        dt.datetime.strptime(tag, "%Y.%m.%d")
    except ValueError as error:
        print(f"invalid calendar date: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
