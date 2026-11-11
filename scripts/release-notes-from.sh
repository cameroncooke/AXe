#!/bin/bash
# Print the version whose CHANGELOG notes a release tag reuses on purpose, or nothing.
#
# Usage: scripts/release-notes-from.sh <tag>
#
# scripts/release.sh --reuse-previous-notes writes "Release-Notes-From: vX.Y.Z" into the
# annotation of the tag it creates. Only an annotated tag counts: a lightweight tag points at
# a commit, and a commit message must not be able to switch off the changelog check.
set -euo pipefail

tag="${1:?usage: scripts/release-notes-from.sh <tag>}"
if [[ "$(git cat-file -t "refs/tags/$tag" 2>/dev/null)" != "tag" ]]; then
  exit 0
fi
git tag -l --format='%(contents)' "$tag" \
  | sed -n -E 's/^Release-Notes-From: v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)[[:space:]]*$/\1/p' \
  | head -n 1
