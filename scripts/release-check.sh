#!/usr/bin/env bash
# The quick release checks in one run: everything short of the end-to-end suites.
#
# Every check runs even when an earlier one fails, so one run shows everything that is wrong.
# The exit status is 0 only when all of them pass.
#
# Environment:
#   RELEASE_CHECK_BASE   Git ref whose released CHANGELOG sections must be unchanged (default: origin/main)
#   RELEASE_CHECK_SKIP   Comma-separated check names to leave out, as the output prints them
#   DEVELOPER_DIR        Xcode used to build and run the unit tests

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/axe-release-check.XXXXXX")"
BASE="${RELEASE_CHECK_BASE:-origin/main}"
passed=0
failed=()
skipped=()

skip_requested() {
    [[ ",${RELEASE_CHECK_SKIP:-}," == *",$1,"* ]]
}

# check NAME COMMAND...: runs the command with its output in a log, and prints one line.
check() {
    local name="$1"
    shift
    if skip_requested "$name"; then
        skipped+=("$name")
        printf '  SKIP  %s\n' "$name"
        return
    fi
    local log="$LOGS/${name// /-}.log"
    local started=$SECONDS
    if "$@" >"$log" 2>&1; then
        passed=$((passed + 1))
        printf '  PASS  %s (%ss)\n' "$name" "$((SECONDS - started))"
    else
        failed+=("$name")
        printf '  FAIL  %s (%ss)\n' "$name" "$((SECONDS - started))"
        tail -n 12 "$log" | sed 's/^/        /'
        printf '        Full output: %s\n' "$log"
    fi
}

skill_lint() {
    command -v npx >/dev/null 2>&1 || { echo "npx is not installed; the skill lint needs Node.js."; return 1; }
    npx --yes skill-check@1.2.0 check Skills/CLI/axe --no-security-scan --fail-on-warning
}

echo "Release checks at $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "  NOTE  the working tree has uncommitted changes; the checks cover them too"
fi

check "changelog" python3 -I scripts/check-changelog-released.py "$BASE"
check "script tests" python3 -I -m unittest discover -s scripts/tests
check "skill copies" diff -r Skills/CLI/axe Sources/AXe/Resources/skills/axe
check "skill lint" skill_lint
check "readiness log" python3 -I scripts/check-release-readiness.py
check "packaging" scripts/release-dry-run.sh
check "unit tests" make test

echo
echo "$passed passed, ${#failed[@]} failed, ${#skipped[@]} skipped."
echo "Not run here: make e2e (hours) and make e2e-devices. See docs/release-readiness.md for their last results."
if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'Failed: %s\n' "$(IFS=,; echo "${failed[*]}" | sed 's/,/, /g')"
    exit 1
fi
rm -rf "$LOGS"
