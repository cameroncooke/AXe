"""Installed Claude Code and Codex plugins update only when a release raises the manifest version."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "plugin-manifest-version.sh"
RELEASE = ROOT / "scripts" / "release.sh"
MANIFESTS = ["agent-plugin/.claude-plugin/plugin.json", "agent-plugin/.codex-plugin/plugin.json"]


@unittest.skipUnless(shutil.which("node"), "node is required for the manifest script")
class PluginManifestVersionTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        for manifest in MANIFESTS:
            path = self.root / manifest
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"name": "axe", "version": "2.0.0",
                                        "interface": {"version": "keep"}}, indent=2) + "\n")

    def tearDown(self):
        self.folder.cleanup()

    def run_script(self, *args):
        return subprocess.run([str(SCRIPT), *args], capture_output=True, text=True,
                              env={**os.environ, "AXE_PLUGIN_ROOT": str(self.root)})

    def test_check_passes_when_both_manifests_match(self):
        self.assertEqual(self.run_script("check", "2.0.0").returncode, 0)

    def test_check_names_each_manifest_that_differs(self):
        result = self.run_script("check", "2.0.5")
        self.assertEqual(result.returncode, 1)
        for manifest in MANIFESTS:
            self.assertIn(f"{manifest} is 2.0.0", result.stderr)

    def test_set_changes_only_the_top_level_version(self):
        before = (self.root / MANIFESTS[0]).read_text()
        self.assertEqual(self.run_script("set", "2.0.5").returncode, 0)
        after = (self.root / MANIFESTS[0]).read_text()
        self.assertEqual(after, before.replace('"version": "2.0.0"', '"version": "2.0.5"'))
        self.assertEqual(json.loads(after)["interface"]["version"], "keep")
        self.assertEqual(self.run_script("check", "2.0.5").returncode, 0)

    def test_paths_lists_the_shipped_manifests(self):
        self.assertEqual(self.run_script("paths").stdout.split(), MANIFESTS)
        for manifest in MANIFESTS:
            self.assertTrue((ROOT / manifest).is_file())


class ReleaseScriptManifestTests(unittest.TestCase):
    def test_release_sets_and_checks_manifests_before_tagging(self):
        text = RELEASE.read_text()
        block = text[text.index("# --- Plugin manifests ---"):text.index("# --- Release notes (tag annotation) ---")]
        self.assertIn('MANIFEST_VERSION="$RELEASE_NOTES_SOURCE_VERSION"', block)
        self.assertIn('"$MANIFEST_SCRIPT" set "$VERSION"', block)
        self.assertIn('! "$MANIFEST_SCRIPT" check "$MANIFEST_VERSION"', block)
        self.assertLess(text.index("# --- Plugin manifests ---"), text.index('run git tag -a "$TAG_NAME"'))

    def test_release_commits_manifests_with_the_changelog(self):
        text = RELEASE.read_text()
        self.assertIn('git add "$CHANGELOG_PATH" $("$MANIFEST_SCRIPT" paths)', text)
        for manifest in MANIFESTS:
            self.assertIn(f'"{manifest}"', text[text.index("RELEASE_MANAGED_FILES=("):text.index("has_unmanaged_changes()")])


if __name__ == "__main__":
    unittest.main()
