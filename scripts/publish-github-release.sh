#!/usr/bin/env bash

set -euo pipefail

TAG=""
TITLE=""
NOTES_FILE=""
TARGET=""
PRERELEASE=false
ASSETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --asset)
      ASSETS+=("${2:-}")
      shift 2
      ;;
    --prerelease)
      PRERELEASE=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" || -z "$TITLE" || -z "$NOTES_FILE" || -z "$TARGET" || ${#ASSETS[@]} -eq 0 ]]; then
  echo "Usage: $0 --tag TAG --title TITLE --notes-file PATH --target SHA [--prerelease] --asset PATH [--asset PATH]" >&2
  exit 1
fi

EDIT_ARGS=(--title "$TITLE" --notes-file "$NOTES_FILE")
CREATE_ARGS=("${EDIT_ARGS[@]}" --target "$TARGET")
if $PRERELEASE; then
  EDIT_ARGS+=(--prerelease)
  CREATE_ARGS+=(--prerelease)
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release edit "$TAG" "${EDIT_ARGS[@]}"
  gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
  gh release create "$TAG" "${CREATE_ARGS[@]}" "${ASSETS[@]}"
fi
