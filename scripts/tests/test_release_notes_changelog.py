"""A production release must not publish another version's release notes."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NOTES = ROOT / "scripts" / "generate-github-release-notes.mjs"
WORKFLOW = ROOT / ".github" / "workflows" / "release-shared.yml"

CHANGELOG = """# Changelog

## [Unreleased]

### Added

- Something new.

## [v1.8.0] - 2026-07-20

### Fixed

- Something old.
"""


@unittest.skipUnless(shutil.which("node"), "node is required for the release-notes script")
class ReleaseNotesChangelogTests(unittest.TestCase):
    def notes(self, version, fallback, changelog=CHANGELOG):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "CHANGELOG.md"
            path.write_text(changelog)
            out = Path(folder) / "notes.md"
            result = subprocess.run(
                ["node", str(NOTES), "--channel", "production", "--version", version,
                 "--fallback", fallback, "--changelog", str(path), "--out", str(out)],
                capture_output=True, text=True)
            return result, out.read_text() if out.exists() else ""

    def test_missing_section_fails_without_fallback(self):
        result, _ = self.notes("2.0.0", "none")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing CHANGELOG section for version: 2.0.0", result.stderr)

    def test_fallback_would_have_published_the_previous_notes(self):
        # The behaviour the production check exists to prevent.
        result, text = self.notes("2.0.0", "newest-older")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Something old.", text)

    def test_finalized_section_is_used(self):
        finalized = CHANGELOG.replace("## [Unreleased]\n", "## [Unreleased]\n\n## [v2.0.0] - 2026-11-12\n", 1)
        result, text = self.notes("2.0.0", "none", finalized)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Something new.", text)
        self.assertNotIn("Something old.", text)


class ReleaseWorkflowChangelogTests(unittest.TestCase):
    def test_production_checks_the_section_before_building(self):
        text = WORKFLOW.read_text()
        check = text.index("- name: Check the changelog has this release's section")
        self.assertLess(check, text.index("- name: Build - IDBKit frameworks"))
        self.assertLess(check, text.index("- name: Notarize - Submit to Apple for notarization"))
        step = text[check:text.index("- name:", check + 1)]
        self.assertIn("if: steps.context.outputs.notesMode == 'changelog'", step)
        self.assertIn("--fallback none", step)

    def test_only_staging_notes_may_fall_back_to_an_older_section(self):
        text = WORKFLOW.read_text()
        step = text[text.index("- name: Generate release notes"):text.index("- name: Upload build artifacts")]
        self.assertIn("steps.context.outputs.notesMode == 'changelog' && 'none' || 'newest-older'", step)


if __name__ == "__main__":
    unittest.main()
