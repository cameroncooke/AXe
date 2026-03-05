#!/bin/bash
set -euo pipefail

# AXe Release Helper
# Creates GitHub releases with automatic semver bumping.
# Building, signing, and packaging are handled by the release workflow.
#
# Usage: scripts/release.sh [VERSION|BUMP_TYPE] [OPTIONS]
# Run with --help for detailed usage information

WORKFLOW_NAME="Release"
WORKFLOW_FILE="release.yml"
WORKFLOW_IDENTIFIER="$WORKFLOW_FILE"

FIRST_ARG="${1:-}"
DRY_RUN=false
VERSION=""
BUMP_TYPE=""
TAP_TARGET=""
TAP_REPO="cameroncooke/homebrew-axe"
TAP_BRANCH="main"
TAP_FORMULA="axe"
STAGING_TAP_REPO="cameroncooke/axe-staging"
STAGING_TAP_BRANCH="main"
STAGING_TAP_FORMULA="axe"
DISPATCH_WORKFLOW=false
REUSE_PREVIOUS_NOTES=false
NO_NOTES_FALLBACK=false

show_help() {
  cat << 'EOF'
AXe Release Helper

Creates releases with automatic semver bumping. Building, signing,
and packaging are handled by the release workflow.

USAGE:
    scripts/release.sh [VERSION|BUMP_TYPE] [OPTIONS]

ARGUMENTS:
    VERSION              Explicit version (e.g. 1.5.0, 2.0.0-beta.1)
    BUMP_TYPE            major | minor [default] | patch

OPTIONS:
    --dry-run            Preview without executing
    --tap-target TARGET  Homebrew tap target: production|staging|both|skip
                         (default derives from version)
    --tap-repo REPO      Override production tap repo
    --tap-branch BRANCH  Override production tap branch
    --tap-formula NAME   Override production tap formula
    --staging-tap-repo REPO     Override staging tap repo
    --staging-tap-branch BRANCH Override staging tap branch
    --staging-tap-formula NAME  Override staging tap formula
    --dispatch-workflow  Trigger workflow_dispatch run with tap inputs
    --reuse-previous-notes
                         Reuse previous version's release notes if target notes are missing
    --no-notes-fallback  Disable fallback to previous version notes
    -h, --help           Show this help

EXAMPLES:
    (no args)            Interactive minor bump
    major                Interactive major bump
    1.5.0                Use specific version
    patch --dry-run      Preview patch bump

EOF

  local highest_version
  highest_version=$(get_highest_version)
  if [[ -n "$highest_version" ]]; then
    echo "CURRENT: $highest_version"
    echo "NEXT: major=$(bump_version "$highest_version" "major") | minor=$(bump_version "$highest_version" "minor") | patch=$(bump_version "$highest_version" "patch")"
  else
    echo "No existing version tags found"
  fi
  echo ""
}

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: $1 not found. Please install it first." >&2
    exit 1
  fi
}

# --- Version helpers ---

get_highest_version() {
  git tag | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$' | sed 's/^v//' | sort -V | tail -1
}

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
    *)
      echo "Error: Unknown bump type: $bump_type" >&2
      exit 1
      ;;
  esac
}

validate_version() {
  local version=$1
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]]; then
    echo "Error: Invalid version format: $version"
    echo "Version must be in format: x.y.z or x.y.z-prerelease (e.g., 1.4.0, 1.4.0-beta.1)"
    return 1
  fi
  return 0
}

compare_versions() {
  local version1=$1
  local version2=$2

  local v1_base=${version1%%-*}
  local v2_base=${version2%%-*}
  local v1_pre=""
  local v2_pre=""

  [[ "$version1" == *-* ]] && v1_pre=${version1#*-}
  [[ "$version2" == *-* ]] && v2_pre=${version2#*-}

  if [[ "$v1_base" == "$v2_base" ]]; then
    if [[ -z "$v1_pre" && -n "$v2_pre" ]]; then
      echo 1; return
    elif [[ -n "$v1_pre" && -z "$v2_pre" ]]; then
      echo -1; return
    elif [[ "$version1" == "$version2" ]]; then
      echo 0; return
    fi
  fi

  local sorted
  sorted=$(printf "%s\n%s" "$version1" "$version2" | sort -V)
  if [[ "$(echo "$sorted" | head -1)" == "$version1" ]]; then
    echo -1
  else
    echo 1
  fi
}

ask_confirmation() {
  local suggested_version=$1
  echo ""
  echo "Suggested next version: $suggested_version"
  read -p "Do you want to use this version? (y/N): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]]
}

ask_yes_no() {
  local prompt="$1"
  read -p "$prompt (y/N): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]]
}

get_version_interactively() {
  echo ""
  echo "Please enter the version manually:"
  while true; do
    read -rp "Version: " manual_version
    if validate_version "$manual_version"; then
      local highest_version
      highest_version=$(get_highest_version)
      if [[ -n "$highest_version" ]]; then
        local comparison
        comparison=$(compare_versions "$manual_version" "$highest_version")
        if [[ $comparison -le 0 ]]; then
          echo "Error: Version $manual_version is not newer than the highest existing version $highest_version"
          continue
        fi
      fi
      VERSION="$manual_version"
      break
    fi
  done
}

run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
    return 0
  fi
  "$@"
}

# Portable in-place sed (BSD/macOS vs GNU/Linux)
sed_inplace() {
  local expr="$1"
  local file="$2"

  if sed --version >/dev/null 2>&1; then
    sed -i -E "$expr" "$file"
  else
    sed -i '' -E "$expr" "$file"
  fi
}

# Rename the first [Unreleased] heading in the CHANGELOG to the target version
# and optionally write the result to a different file.
# Exit code 3 means the heading was already renamed or not found (non-fatal skip).
prepare_changelog_for_release_notes() {
  local source_path="$1"
  local destination_path="$2"
  local target_version="$3"

  node - "$source_path" "$destination_path" "$target_version" <<'NODE'
const fs = require('fs');

const [sourcePath, destinationPath, targetVersion] = process.argv.slice(2);
const versionHeadingRegex = /^##\s+\[([^\]]+)\](?:\s+-\s+.*)?\s*$/;
const normalizeVersion = (value) => value.trim().replace(/^v/, '');

try {
  const changelog = fs.readFileSync(sourcePath, 'utf8');
  const lines = changelog.split(/\r?\n/);
  const normalizedTargetVersion = normalizeVersion(targetVersion);
  let firstHeadingIndex = -1;
  let firstHeadingLabel = '';

  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(versionHeadingRegex);
    if (!match) {
      continue;
    }

    const label = match[1].trim();
    if (normalizeVersion(label) === normalizedTargetVersion) {
      process.exit(3);
    }

    if (firstHeadingIndex === -1) {
      firstHeadingIndex = index;
      firstHeadingLabel = label;
    }
  }

  if (firstHeadingIndex === -1 || firstHeadingLabel !== 'Unreleased') {
    process.exit(3);
  }

  const today = new Date().toISOString().slice(0, 10);
  lines[firstHeadingIndex] = `## [v${normalizedTargetVersion}] - ${today}`;
  fs.writeFileSync(destinationPath, `${lines.join('\n')}`, 'utf8');
  process.exit(0);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`Failed to prepare changelog for release notes: ${message}`);
  process.exit(1);
}
NODE
}

# --- Parse arguments ---

for arg in "$@"; do
  if [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
    show_help
    exit 0
  fi
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --tap-target)
      shift; TAP_TARGET="${1:-}"
      ;;
    --tap-repo)
      shift; TAP_REPO="${1:-}"
      ;;
    --tap-branch)
      shift; TAP_BRANCH="${1:-}"
      ;;
    --tap-formula)
      shift; TAP_FORMULA="${1:-}"
      ;;
    --staging-tap-repo)
      shift; STAGING_TAP_REPO="${1:-}"
      ;;
    --staging-tap-branch)
      shift; STAGING_TAP_BRANCH="${1:-}"
      ;;
    --staging-tap-formula)
      shift; STAGING_TAP_FORMULA="${1:-}"
      ;;
    --dispatch-workflow)
      DISPATCH_WORKFLOW=true
      ;;
    --reuse-previous-notes)
      REUSE_PREVIOUS_NOTES=true
      ;;
    --no-notes-fallback)
      NO_NOTES_FALLBACK=true
      ;;
    major|minor|patch)
      if [[ -n "$VERSION" ]]; then
        echo "Error: Cannot specify both explicit version and bump type." >&2
        exit 1
      fi
      BUMP_TYPE=$1
      ;;
    *)
      if [[ -z "$VERSION" ]] && [[ "$1" != "--"* ]]; then
        VERSION=$1
      elif [[ "$1" != "--"* ]]; then
        echo "Error: Unexpected argument: $1" >&2
        exit 1
      fi
      ;;
  esac
  shift || true
done

# --- Preflight checks ---

ensure_command gh
ensure_command jq

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated. Run 'gh auth login'." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
  echo "Error: Releases must be created from the main branch."
  echo "Current branch: $BRANCH"
  echo "Please switch to main and try again."
  exit 1
fi

REPO_NAME=$(gh repo view --json nameWithOwner -q .nameWithOwner)

git fetch --tags >/dev/null 2>&1 || true

# --- Determine version ---

if [[ -z "$VERSION" && -z "$BUMP_TYPE" ]]; then
  BUMP_TYPE="minor"
fi

if [[ -n "$VERSION" && -n "$BUMP_TYPE" ]]; then
  echo "Error: Specify either an explicit version or a bump type, not both." >&2
  exit 1
fi

if [[ -n "$VERSION" ]]; then
  if ! validate_version "$VERSION"; then
    exit 1
  fi
fi

if [[ -n "$BUMP_TYPE" ]]; then
  HIGHEST_VERSION=$(get_highest_version)
  if [[ -z "$HIGHEST_VERSION" ]]; then
    echo "No existing version tags found. Please provide a version manually."
    get_version_interactively
  else
    SUGGESTED_VERSION=$(bump_version "$HIGHEST_VERSION" "$BUMP_TYPE")
    if ask_confirmation "$SUGGESTED_VERSION"; then
      VERSION="$SUGGESTED_VERSION"
    else
      get_version_interactively
    fi
  fi
fi

if [[ -z "$VERSION" ]]; then
  echo "Error: No version determined" >&2
  exit 1
fi

# Validate that the new version is actually newer
HIGHEST_VERSION=$(get_highest_version)
PREVIOUS_VERSION="$HIGHEST_VERSION"
if [[ -n "$HIGHEST_VERSION" ]]; then
  COMPARISON=$(compare_versions "$VERSION" "$HIGHEST_VERSION")
  if [[ $COMPARISON -le 0 ]]; then
    echo "Error: Version $VERSION is not newer than the highest existing version $HIGHEST_VERSION"
    exit 1
  fi
fi

TAG_NAME="v$VERSION"

# Check tag doesn't already exist
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  echo "Error: Tag $TAG_NAME already exists locally."
  exit 1
fi
if git ls-remote --tags origin | grep -q "refs/tags/$TAG_NAME$"; then
  echo "Error: Tag $TAG_NAME already exists on origin."
  exit 1
fi

# Derive tap target: prerelease -> staging, else production
if [[ -z "$TAP_TARGET" ]]; then
  if [[ "$VERSION" == *"-"* ]]; then
    TAP_TARGET="staging"
  else
    TAP_TARGET="production"
  fi
fi

# --- Release-managed files and working tree check ---

RELEASE_MANAGED_FILES=(
  "CHANGELOG.md"
)

has_unmanaged_changes() {
  local exclude_args=()
  for f in "${RELEASE_MANAGED_FILES[@]}"; do
    exclude_args+=(":(exclude)$f")
  done
  ! git diff-index --quiet HEAD -- . "${exclude_args[@]}"
}

if ! $DRY_RUN; then
  if has_unmanaged_changes; then
    echo "Error: Working directory has uncommitted changes outside release-managed files."
    echo "Please commit or stash those changes before creating a release."
    exit 1
  fi
else
  if has_unmanaged_changes; then
    echo "Warning: Dry-run: working directory has unmanaged changes (continuing)."
  fi
fi

# --- Changelog handling ---

CHANGELOG_PATH="CHANGELOG.md"
CHANGELOG_UPDATED=false
CHANGELOG_FOR_VALIDATION="$CHANGELOG_PATH"
CHANGELOG_VALIDATION_TEMP=""

if $DRY_RUN; then
  CHANGELOG_VALIDATION_TEMP=$(mktemp "${TMPDIR:-/tmp}/axe-changelog-validation.XXXXXX")
  if prepare_changelog_for_release_notes "$CHANGELOG_PATH" "$CHANGELOG_VALIDATION_TEMP" "$VERSION"; then
    CHANGELOG_FOR_VALIDATION="$CHANGELOG_VALIDATION_TEMP"
    echo "Dry-run: prepared release changelog from [Unreleased] in a temp file."
  else
    PREPARE_STATUS=$?
    if [[ $PREPARE_STATUS -eq 3 ]]; then
      rm -f "$CHANGELOG_VALIDATION_TEMP"
      CHANGELOG_VALIDATION_TEMP=""
    else
      rm -f "$CHANGELOG_VALIDATION_TEMP"
      exit $PREPARE_STATUS
    fi
  fi
else
  if prepare_changelog_for_release_notes "$CHANGELOG_PATH" "$CHANGELOG_PATH" "$VERSION"; then
    CHANGELOG_UPDATED=true
    echo "Renamed CHANGELOG heading [Unreleased] -> [v$VERSION]"
  else
    PREPARE_STATUS=$?
    if [[ $PREPARE_STATUS -ne 3 ]]; then
      exit $PREPARE_STATUS
    fi
  fi
fi

# --- Validate changelog release notes ---

echo ""
echo "Validating CHANGELOG release notes for v$VERSION..."
RELEASE_NOTES_TMP=$(mktemp "${TMPDIR:-/tmp}/axe-release-notes.XXXXXX")
RELEASE_NOTES_SOURCE_VERSION="$VERSION"
if node scripts/generate-github-release-notes.mjs --version "$VERSION" --changelog "$CHANGELOG_FOR_VALIDATION" --out "$RELEASE_NOTES_TMP"; then
  echo "CHANGELOG entry found and release notes generated for v$VERSION."
else
  FALLBACK_ALLOWED=true
  if $NO_NOTES_FALLBACK; then
    FALLBACK_ALLOWED=false
  fi

  if [[ "$FALLBACK_ALLOWED" == "true" && -n "$PREVIOUS_VERSION" && "$PREVIOUS_VERSION" != "$VERSION" ]]; then
    USE_FALLBACK=false
    if $REUSE_PREVIOUS_NOTES; then
      USE_FALLBACK=true
    elif [[ -t 0 ]]; then
      echo ""
      echo "No release notes found for v$VERSION (and no [Unreleased] entry to promote)."
      if ask_yes_no "Reuse release notes from v$PREVIOUS_VERSION?"; then
        USE_FALLBACK=true
      fi
    fi

    if [[ "$USE_FALLBACK" == "true" ]]; then
      if node scripts/generate-github-release-notes.mjs --version "$PREVIOUS_VERSION" --changelog "$CHANGELOG_FOR_VALIDATION" --out "$RELEASE_NOTES_TMP"; then
        RELEASE_NOTES_SOURCE_VERSION="$PREVIOUS_VERSION"
        echo "Using release notes from v$PREVIOUS_VERSION for v$VERSION."
      else
        echo "Error: Failed to generate fallback release notes from v$PREVIOUS_VERSION." >&2
        rm -f "$RELEASE_NOTES_TMP"
        [[ -n "$CHANGELOG_VALIDATION_TEMP" ]] && rm -f "$CHANGELOG_VALIDATION_TEMP"
        if $CHANGELOG_UPDATED; then
          git checkout -- "$CHANGELOG_PATH"
        fi
        exit 1
      fi
    fi
  fi

  if [[ "$RELEASE_NOTES_SOURCE_VERSION" == "$VERSION" ]]; then
    echo "Error: Failed to generate release notes from CHANGELOG." >&2
    echo "Ensure CHANGELOG.md has an entry for version $VERSION or [Unreleased]." >&2
    echo "If this is a deploy-only patch, rerun with --reuse-previous-notes to reuse v$PREVIOUS_VERSION notes." >&2
    rm -f "$RELEASE_NOTES_TMP"
    [[ -n "$CHANGELOG_VALIDATION_TEMP" ]] && rm -f "$CHANGELOG_VALIDATION_TEMP"
    # Restore changelog if we modified it
    if $CHANGELOG_UPDATED; then
      git checkout -- "$CHANGELOG_PATH"
    fi
    exit 1
  fi
fi
rm -f "$RELEASE_NOTES_TMP"
[[ -n "$CHANGELOG_VALIDATION_TEMP" ]] && rm -f "$CHANGELOG_VALIDATION_TEMP"

# --- Release notes (tag annotation) ---

RELEASE_NOTES="Release $TAG_NAME"

# --- Commit, tag, and push ---

echo ""
echo "Preparing release for $TAG_NAME"
echo "Workflow: $WORKFLOW_NAME"
echo "Tap target: $TAP_TARGET"

if $CHANGELOG_UPDATED && ! $DRY_RUN; then
  echo "Committing changelog update..."
  git add "$CHANGELOG_PATH"
  git commit -m "Finalize changelog for v$VERSION"
fi

TMP_NOTES=$(mktemp)
printf '%s\n' "$RELEASE_NOTES" > "$TMP_NOTES"
trap 'rm -f "$TMP_NOTES"' EXIT

run git tag -a "$TAG_NAME" -F "$TMP_NOTES"
if ! $DRY_RUN; then
  echo "Tag $TAG_NAME created."
fi

HEAD_SHA=$(git rev-parse HEAD)

echo ""
echo "Pushing to origin..."
run git push origin "$BRANCH"
run git push origin "$TAG_NAME"

if $DRY_RUN; then
  echo ""
  echo "Dry-run: skipping GitHub Actions workflow monitoring."
  exit 0
fi

echo "Tag $TAG_NAME pushed to origin."

# --- Monitor workflow ---

echo ""
echo "Monitoring GitHub Actions workflow..."
echo "This may take a few minutes..."

RUN_ID=""
FALLBACK_USED=false
for attempt in $(seq 1 30); do
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
  echo "  Waiting for workflow to appear... (attempt $attempt/30)"
  sleep 10
done

if [[ -z "$RUN_ID" ]]; then
  echo "Warning: Could not find workflow run for commit $HEAD_SHA."
  echo "Please check manually: https://github.com/$REPO_NAME/actions"
  exit 1
fi

echo "Workflow run ID: $RUN_ID"
echo "Watching workflow progress..."
echo "(Press Ctrl+C to detach and monitor manually)"
echo ""

if gh run watch "$RUN_ID" --exit-status; then
  echo ""
  echo "Release v$VERSION completed successfully!"
  echo "View release: https://github.com/$REPO_NAME/releases/tag/$TAG_NAME"
else
  WATCH_EXIT=$?
  echo ""
  echo "CI workflow monitoring exited with status $WATCH_EXIT."
  echo ""

  # Query the actual workflow state — gh run watch can fail due to network
  # issues even when the job is still running or has already succeeded.
  JOB_CONCLUSION=""
  JOB_STATUS=""
  for poll in $(seq 1 3); do
    JOB_JSON=$(gh run view "$RUN_ID" --json jobs --jq '.jobs[] | select(.name=="build-and-release") | {conclusion,status}' 2>/dev/null || true)
    if [[ -n "$JOB_JSON" ]]; then
      JOB_CONCLUSION=$(echo "$JOB_JSON" | jq -r '.conclusion // empty')
      JOB_STATUS=$(echo "$JOB_JSON" | jq -r '.status // empty')
      break
    fi
    sleep 5
  done

  if [[ "$JOB_CONCLUSION" == "success" ]]; then
    echo "Workflow monitoring lost connection, but 'build-and-release' job concluded SUCCESS."
    echo "Tag $TAG_NAME is kept."
    echo "View release: https://github.com/$REPO_NAME/releases/tag/$TAG_NAME"
    exit 0
  fi

  if [[ "$JOB_STATUS" == "in_progress" || "$JOB_STATUS" == "queued" ]]; then
    echo "The 'build-and-release' job is still $JOB_STATUS."
    echo "The local monitoring connection was lost but the workflow continues on GitHub."
    echo ""
    echo "Tag $TAG_NAME is kept. Do NOT re-run the release script."
    echo ""
    echo "To resume monitoring:"
    echo "  gh run watch $RUN_ID --exit-status"
    echo ""
    echo "To check status:"
    echo "  gh run view $RUN_ID"
    echo "  https://github.com/$REPO_NAME/actions"
    exit 0
  fi

  if [[ -z "$JOB_CONCLUSION" && -z "$JOB_STATUS" ]]; then
    echo "Could not reach GitHub API to determine workflow state."
    echo "The workflow may still be running."
    echo ""
    echo "Tag $TAG_NAME is kept to avoid deleting a potentially successful release."
    echo ""
    echo "Once connectivity is restored, check status with:"
    echo "  gh run view $RUN_ID"
    echo ""
    echo "If the workflow failed, clean up manually with:"
    echo "  gh release delete $TAG_NAME --yes 2>/dev/null; git push origin :refs/tags/$TAG_NAME; git tag -d $TAG_NAME"
    exit 1
  fi

  # Job genuinely failed — clean up
  echo "Workflow failed (conclusion: $JOB_CONCLUSION)."
  echo ""
  echo "Cleaning up tags (keeping version commit)..."

  if gh release view "$TAG_NAME" >/dev/null 2>&1; then
    echo "  - Deleting draft release $TAG_NAME..."
    gh release delete "$TAG_NAME" --yes || true
  fi

  echo "  - Deleting remote tag $TAG_NAME..."
  git push origin ":refs/tags/$TAG_NAME" 2>/dev/null || true

  echo "  - Deleting local tag $TAG_NAME..."
  git tag -d "$TAG_NAME" 2>/dev/null || true

  echo ""
  echo "Tag cleanup complete."
  echo ""
  echo "The version commit remains in your history."
  echo "To retry after fixing issues:"
  echo "  1. Fix the CI issues"
  echo "  2. Commit your fixes"
  echo "  3. Run: ./scripts/release.sh $VERSION"
  echo ""
  echo "To see what failed: gh run view $RUN_ID --log-failed"
  exit 1
fi

# --- Optional workflow dispatch ---

if $DISPATCH_WORKFLOW; then
  echo ""
  echo "Dispatching release workflow with explicit tap targets..."
  gh workflow run "$WORKFLOW_FILE" \
    -f tag="$TAG_NAME" \
    -f tap_repo="$TAP_REPO" \
    -f tap_formula="$TAP_FORMULA" \
    -f tap_branch="$TAP_BRANCH" \
    -f staging_tap_repo="$STAGING_TAP_REPO" \
    -f staging_tap_formula="$STAGING_TAP_FORMULA" \
    -f staging_tap_branch="$STAGING_TAP_BRANCH" \
    -f tap_target="$TAP_TARGET" \
    -f create_release=true \
    -f prerelease=$([[ "$VERSION" == *"-"* ]] && echo true || echo false)
  echo "Workflow dispatch requested (tag=$TAG_NAME, tap_target=$TAP_TARGET)."
fi
