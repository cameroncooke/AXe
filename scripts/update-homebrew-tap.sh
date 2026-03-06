#!/usr/bin/env bash

set -euo pipefail

TARGET=""
VERSION=""
ARCHIVE_URL=""
ARCHIVE_SHA=""
HOMEPAGE=""
TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --archive-url)
      ARCHIVE_URL="${2:-}"
      shift 2
      ;;
    --archive-sha)
      ARCHIVE_SHA="${2:-}"
      shift 2
      ;;
    --homepage)
      HOMEPAGE="${2:-}"
      shift 2
      ;;
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET" || -z "$VERSION" || -z "$ARCHIVE_URL" || -z "$ARCHIVE_SHA" || -z "$HOMEPAGE" || -z "$TOKEN" ]]; then
  echo "Usage: $0 --target production|staging --version VERSION --archive-url URL --archive-sha SHA --homepage URL --token TOKEN" >&2
  exit 1
fi

case "$TARGET" in
  production)
    TAP_REPO="cameroncooke/homebrew-axe"
    ;;
  staging)
    TAP_REPO="cameroncooke/homebrew-axe-staging"
    ;;
  *)
    echo "Unsupported target: $TARGET" >&2
    exit 1
    ;;
esac

TAP_BRANCH="main"
TAP_FORMULA="axe"
FORMULA_CLASS="Axe"
WORK_DIR="tap-repo-${TARGET}"

rm -rf "$WORK_DIR"
GH_TOKEN="$TOKEN" gh repo clone "$TAP_REPO" "$WORK_DIR"
cd "$WORK_DIR"
git checkout "$TAP_BRANCH"

FORMULA_FILE="Formula/${TAP_FORMULA}.rb"
if [[ ! -f "$FORMULA_FILE" ]]; then
  echo "Formula file not found: $FORMULA_FILE" >&2
  exit 1
fi

"${GITHUB_WORKSPACE}/scripts/generate-homebrew-formula.sh" \
  --formula-class "$FORMULA_CLASS" \
  --homepage "$HOMEPAGE" \
  --version "$VERSION" \
  --url "$ARCHIVE_URL" \
  --sha256 "$ARCHIVE_SHA" \
  > "$FORMULA_FILE"

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "$FORMULA_FILE"
if ! git diff --staged --quiet; then
  git commit -m "Update axe to v${VERSION}"
  AUTH_HEADER=$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')
  git -c http.https://github.com/.extraheader="AUTHORIZATION: basic ${AUTH_HEADER}" push origin "$TAP_BRANCH"
fi
