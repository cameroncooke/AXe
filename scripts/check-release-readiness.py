#!/usr/bin/env python3
"""Fail when docs/release-readiness.md still has open items.

Usage: scripts/check-release-readiness.py [PATH]   (default: docs/release-readiness.md)

An item is a list line that starts with a checkbox. "[x]" is done; "[ ]" (not started),
"[~]" (in progress) and "[!]" (blocked) are open. Each open item is printed under the
heading of its section, and the exit status is 1 when there is at least one.
"""

import re
import sys
from pathlib import Path

ITEM = re.compile(r"^\s*- \[(.)\] (.*)$")
STATES = {" ": "not started", "~": "in progress", "!": "blocked"}


def shortened(text: str, limit: int = 100) -> str:
    """The start of an item, cut at a word, so a long item still fits on a line."""
    if len(text) <= limit:
        return text.rstrip(".")
    return text[:limit].rsplit(" ", 1)[0].rstrip(".,;:") + "…"


def open_items(text: str) -> list[tuple[str, str, str]]:
    """(section heading, state, start of the item) for every open item, in order."""
    found = []
    section = ""
    for line in text.splitlines():
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        match = ITEM.match(line)
        if not match or match.group(1) == "x":
            continue
        state = STATES.get(match.group(1), f"unknown mark [{match.group(1)}]")
        found.append((section, state, shortened(match.group(2))))
    return found


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "docs/release-readiness.md"
    try:
        items = open_items(path.read_text())
    except OSError as error:
        print(f"Could not read {path}: {error}", file=sys.stderr)
        return 2
    if not items:
        print(f"{path.name}: no open items")
        return 0
    print(f"{path.name}: {len(items)} open item{'s' if len(items) != 1 else ''}")
    for section, state, summary in items:
        print(f"  {state}: {summary} ({section})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
