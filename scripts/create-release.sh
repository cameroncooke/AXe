#!/bin/bash
set -euo pipefail

WORKFLOW_NAME="Release"
WORKFLOW_FILE="release.yml"
WORKFLOW_IDENTIFIER="$WORKFLOW_FILE"

log_info() { printf '\n🔷 %s\n' "$1"; }
log_error() { printf '❌ %s\n' "$1" >&2; exit 1; }
log_success() { printf '\n✅ %s\n' "$1"; }

usage() {
  cat <<'USAGE'
AXe Release Helper

Usage: scripts/create-release.sh [VERSION|major|minor|patch] [--notes-file FILE] [--dry-run]
       scripts/create-release.sh --help

Arguments:
  VERSION           Explicit semantic version (e.g. 1.4.0 or 1.5.0-beta.1)
  major|minor|patch Semantic version bump type (defaults to minor when omitted)

Options:
  --notes-file FILE  Read release notes from FILE instead of prompting
  --dry-run          Preview actions without pushing
  -h, --help         Show this help text
USAGE
}

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "$1 not found. Please install it first."
  fi
}

# --- Version helpers ---
parse_version() {
  echo "$1" | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+)(-.*)?$/\1 \2 \3 \4/'
}

bump_version() {
  local current_version=$1
  local bump_type=$2

  if [[ -z "$current_version" ]]; then
    case $bump_type in
      major) echo "1.0.0" ;;
      minor) echo "0.1.0" ;;
      patch) echo "0.0.1" ;;
    esac
    return
  fi

  local parsed=($(parse_version "$current_version"))
  local major=${parsed[0]}
  local minor=${parsed[1]}
  local patch=${parsed[2]}

  case $bump_type in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    *) log_error "Unknown bump type: $bump_type" ;;
  esac
}

latest_version() {
  git tag | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$' | sed 's/^v//' | sort -V | tail -1
}

# --- Parse arguments ---
VERSION=""
BUMP_TYPE=""
NOTES_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file)
      shift
      [[ $# -gt 0 ]] || log_error "--notes-file requires a path"
      NOTES_FILE=$1
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    major|minor|patch)
      if [[ -n "$VERSION" ]]; then
        log_error "Cannot specify both explicit version and bump type."
      fi
      BUMP_TYPE=$1
      ;;
    *)
      if [[ -z "$VERSION" ]]; then
        VERSION=$1
      else
        log_error "Unexpected argument: $1"
      fi
      ;;
  esac
  shift || true
done

ensure_command gh
ensure_command jq

if ! gh auth status >/dev/null 2>&1; then
  log_error "GitHub CLI is not authenticated. Run 'gh auth login'."
fi

REPO_NAME=$(gh repo view --json nameWithOwner -q .nameWithOwner)

git fetch --tags >/dev/null 2>&1 || true

LATEST_VERSION=$(latest_version)
if [[ -n "$LATEST_VERSION" ]]; then
  log_info "Latest version: $LATEST_VERSION"
else
  log_info "No previous versions found."
fi

if [[ -n "$VERSION" && -n "$BUMP_TYPE" ]]; then
  log_error "Specify either an explicit version or a bump type, not both."
fi

if [[ -n "$BUMP_TYPE" ]]; then
  VERSION=$(bump_version "$LATEST_VERSION" "$BUMP_TYPE")
  log_info "Bump type '$BUMP_TYPE' selected -> $VERSION"
fi

if [[ -z "$VERSION" ]]; then
  DEFAULT_VERSION=$(bump_version "$LATEST_VERSION" "minor")
  read -rp "Enter version [$DEFAULT_VERSION]: " VERSION_INPUT
  if [[ -z "$VERSION_INPUT" ]]; then
    VERSION=$DEFAULT_VERSION
  else
    VERSION=$VERSION_INPUT
  fi
fi

[[ -n "$VERSION" ]] || log_error "No version provided."

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]]; then
  log_error "Invalid version format '$VERSION'."
fi

TAG_NAME="v$VERSION"

if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  log_error "Tag $TAG_NAME already exists locally."
fi

if git ls-remote --tags origin | grep -q "refs/tags/$TAG_NAME$"; then
  log_error "Tag $TAG_NAME already exists on origin."
fi

if ! git diff-index --quiet HEAD --; then
  log_error "Working tree is not clean. Commit or stash changes first."
fi

if [[ -n "$NOTES_FILE" ]]; then
  [[ -f "$NOTES_FILE" ]] || log_error "Release notes file not found: $NOTES_FILE"
  RELEASE_NOTES=$(<"$NOTES_FILE")
else
  log_info "Enter release notes (Ctrl+D to finish):"
  RELEASE_NOTES=$(cat)
fi

if [[ -z "$RELEASE_NOTES" ]]; then
  RELEASE_NOTES="Release $TAG_NAME"
fi

log_info "Preparing release for $TAG_NAME"
log_info "Workflow: $WORKFLOW_NAME"

TMP_NOTES=$(mktemp)
printf '%s\n' "$RELEASE_NOTES" > "$TMP_NOTES"
trap 'rm -f "$TMP_NOTES"' EXIT

if $DRY_RUN; then
  log_info "[dry-run] Would create annotated tag $TAG_NAME"
else
  git tag -a "$TAG_NAME" -F "$TMP_NOTES"
  log_success "Tag $TAG_NAME created."
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
HEAD_SHA=$(git rev-parse HEAD)

if $DRY_RUN; then
  log_info "[dry-run] Would push branch $CURRENT_BRANCH and tag $TAG_NAME"
else
  git push origin "$CURRENT_BRANCH"
  git push origin "$TAG_NAME"
  log_success "Tag $TAG_NAME pushed to origin."
fi

if $DRY_RUN; then
  log_info "[dry-run] Skipping workflow monitoring."
  exit 0
fi

log_info "Waiting for GitHub Actions workflow to start..."
RUN_ID=""
FALLBACK_USED=false
for attempt in {1..30}; do
  RUN_JSON=$(gh run list --workflow "$WORKFLOW_IDENTIFIER" --limit 10 --json databaseId,headSha,status,event 2>/dev/null || true)
  if [[ -z "$RUN_JSON" ]]; then
    RUN_JSON="[]"
  fi
  RUN_ID=$(echo "$RUN_JSON" | jq -r ".[] | select(.headSha == \"$HEAD_SHA\") | .databaseId" | head -n1)
  if [[ -z "$RUN_ID" && "$WORKFLOW_IDENTIFIER" == "$WORKFLOW_FILE" && "$FALLBACK_USED" == "false" ]]; then
    WORKFLOW_IDENTIFIER="$WORKFLOW_NAME"
    FALLBACK_USED=true
    continue
  fi
  if [[ -n "$RUN_ID" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "$RUN_ID" ]]; then
  log_error "Could not find workflow run for commit $HEAD_SHA. Monitor manually on GitHub."
fi

log_info "Monitoring workflow run ID $RUN_ID..."
if gh run watch "$RUN_ID" --exit-status; then
  log_success "Workflow succeeded!"
  log_info "Release will be published automatically."
  log_info "https://github.com/$REPO_NAME/releases/tag/$TAG_NAME"
else
  log_info "Workflow failed. Cleaning up..."
  if gh release view "$TAG_NAME" >/dev/null 2>&1; then
    gh release delete "$TAG_NAME" --yes || true
  fi
  git push origin ":refs/tags/$TAG_NAME" || true
  git tag -d "$TAG_NAME" || true
  log_error "Release workflow failed. Fix issues and rerun the script with version $VERSION."
fi
