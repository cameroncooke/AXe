#!/bin/bash
set -e

# Usage: ./release.sh [<version>] [--dry-run]
VERSION=""
DRY_RUN=false

# Parse arguments: set DRY_RUN for --dry-run, and set VERSION to the first non-flag argument
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    DRY_RUN=true
  elif [[ -z "$VERSION" && ! "$arg" =~ ^- ]]; then
    VERSION="$arg"
  fi
done

validate_version_format() {
  if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+\.[0-9]+)?$ ]]; then
    echo ""
    echo "❌ Invalid version format: $1"
    echo "Version must be in format: x.y.z or x.y.z-tag.n (e.g., 1.4.0 or 1.4.0-beta.3)"
    exit 1
  fi
}

run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

if [ -n "$VERSION" ]; then
  validate_version_format "$VERSION"
fi

# Check existing latest version (use git tags)
echo ""
LATEST_TAG=$(git describe --tags --abbrev=0)
LATEST_TAG_STRIPPED=${LATEST_TAG#v}
echo "Latest version: $LATEST_TAG_STRIPPED"

# If version isn't supplied via agument then read from input and validate that the version is higher than previous release
if [ -z "$VERSION" ]; then
  read -p "New version: " VERSION
  validate_version_format "$VERSION"
else
  echo "New version: $VERSION"
fi

# Validate new version is greater than current version
greater_version=$(printf "%s\n%s" "$LATEST_TAG_STRIPPED" "$VERSION" | sort -V | tail -n1)
if [ "$greater_version" != "$VERSION" ]; then
  echo ""
  echo "❌ Version $VERSION must be greater than the latest release ($LATEST_TAG_STRIPPED)."
  exit 1
fi

# Version update
echo ""
echo "🔧 Preparing to release version $VERSION..."

# Git operations
echo ""
echo "📦 Tagging version..."
run "git tag \"v$VERSION\""

echo ""
echo "🚀 Pushing to origin..."
run "git push origin main --tags"

echo ""
echo "📦 Creating GitHub release..."
run "gh release create \"v$VERSION\" --generate-notes -t \"Release $VERSION\""

# Completion message
echo ""
echo "✅ Release $VERSION complete!"
echo "📝 Don't forget to update the changelog"