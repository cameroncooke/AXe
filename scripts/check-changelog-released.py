#!/usr/bin/env python3
"""Fail when an already-released CHANGELOG.md section differs from the base ref.

Usage: scripts/check-changelog-released.py [BASE_REF]   (default: origin/main)

Released sections start at the first "## [v" heading. Adding new release
sections above the existing ones is allowed; editing, removing or reordering
existing released sections is not.
"""

import subprocess
import sys
from pathlib import Path

MARKER = "## [v"


def released_part(text: str) -> str:
    if text.startswith(MARKER):
        return text
    index = text.find("\n" + MARKER)
    return "" if index < 0 else text[index + 1:]


def main() -> int:
    base_ref = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
    root = Path(__file__).resolve().parent.parent
    try:
        base_text = subprocess.run(
            ["git", "show", f"{base_ref}:CHANGELOG.md"],
            cwd=root, check=True, capture_output=True, text=True,
        ).stdout
    except subprocess.CalledProcessError as error:
        print(f"cannot read CHANGELOG.md at {base_ref}: {error.stderr.strip()}", file=sys.stderr)
        return 2

    base = released_part(base_text)
    current = released_part((root / "CHANGELOG.md").read_text())
    if current == base:
        return 0
    if current.endswith(base):
        added = current[: len(current) - len(base)]
        if added.startswith(MARKER) and added.endswith("\n"):
            return 0

    print(
        "CHANGELOG.md: released version sections must not change "
        f"(compared with {base_ref}).\n"
        "Put new entries under `## [Unreleased]`, and restore released sections "
        f"with: git show {base_ref}:CHANGELOG.md",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
