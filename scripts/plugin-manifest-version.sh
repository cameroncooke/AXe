#!/bin/bash
# Set or check the version in both agent plugin manifests.
#
# Claude Code and Codex cache an installed plugin by its manifest version, so a release with its own
# CHANGELOG section must raise both manifests to that version, or installed plugins keep the skill
# they first installed. A release that reuses older notes keeps the manifests at that older version.
#
# Usage: scripts/plugin-manifest-version.sh check VERSION   Fails, naming each manifest that differs
#        scripts/plugin-manifest-version.sh set VERSION     Changes only the top-level "version"
#        scripts/plugin-manifest-version.sh paths           Prints the manifest paths
#
# Environment:
#   AXE_PLUGIN_ROOT   Repository root that holds agent-plugin/ (default: this checkout)
set -euo pipefail

ROOT="${AXE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFESTS=(
  "agent-plugin/.claude-plugin/plugin.json"
  "agent-plugin/.codex-plugin/plugin.json"
)

usage() {
  echo "Usage: $0 check VERSION | set VERSION | paths" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
COMMAND="$1"
case "$COMMAND" in
  paths)
    printf '%s\n' "${MANIFESTS[@]}"
    exit 0
    ;;
  check|set)
    [[ $# -eq 2 && -n "$2" ]] || usage
    ;;
  *)
    usage
    ;;
esac

node - "$COMMAND" "$2" "$ROOT" "${MANIFESTS[@]}" <<'NODE'
const fs = require('fs');
const path = require('path');
const [command, version, root, ...files] = process.argv.slice(2);
const wrong = [];
for (const file of files) {
  const location = path.join(root, file);
  const text = fs.readFileSync(location, 'utf8');
  const current = JSON.parse(text).version;
  if (command === 'check') {
    if (current !== version) wrong.push(`${file} is ${current === undefined ? 'missing its version' : current}`);
    continue;
  }
  if (current === version) continue;
  // Replace the value in place so the rest of the file keeps its formatting, then confirm the
  // top-level version is the one that changed.
  const updated = text.replace(/("version"\s*:\s*")[^"]*(")/, `$1${version}$2`);
  if (JSON.parse(updated).version !== version) {
    console.error(`Could not set the top-level version in ${file}.`);
    process.exit(1);
  }
  fs.writeFileSync(location, updated);
}
if (wrong.length > 0) {
  console.error(`Plugin manifests must be ${version}: ${wrong.join("; ")}.`);
  process.exit(1);
}
NODE
