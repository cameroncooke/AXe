"""A production release must not publish another version's notes unless that was chosen on purpose."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NOTES = ROOT / "scripts" / "generate-github-release-notes.mjs"
NOTES_FROM = ROOT / "scripts" / "release-notes-from.sh"
RELEASE = ROOT / "scripts" / "release.sh"
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
class ReleaseNotesTests(unittest.TestCase):
    def notes(self, version, *options, changelog=CHANGELOG):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "CHANGELOG.md"
            path.write_text(changelog)
            out = Path(folder) / "notes.md"
            result = subprocess.run(
                ["node", str(NOTES), "--channel", "production", "--version", version,
                 "--changelog", str(path), "--out", str(out), *options],
                capture_output=True, text=True)
            return result, out.read_text() if out.exists() else ""

    def test_missing_section_fails_without_fallback(self):
        result, _ = self.notes("2.0.0", "--fallback", "none")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing CHANGELOG section for version: 2.0.0", result.stderr)

    def test_finalized_section_is_used(self):
        finalized = CHANGELOG.replace("## [Unreleased]\n", "## [Unreleased]\n\n## [v2.0.0] - 2026-11-12\n", 1)
        result, text = self.notes("2.0.0", "--fallback", "none", changelog=finalized)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Something new.", text)
        self.assertNotIn("Something old.", text)

    def test_deliberate_reuse_uses_the_named_notes_and_says_so(self):
        result, text = self.notes("1.8.1", "--fallback", "none", "--notes-from", "1.8.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Something old.", text)
        self.assertIn("Notes fallback: using CHANGELOG entry from `1.8.0` for `1.8.1`", text)
        self.assertIn("AXe-macOS-v1.8.1-universal.tar.gz", text)

    def test_a_release_with_its_own_section_ignores_the_reuse_marker(self):
        finalized = CHANGELOG.replace("## [Unreleased]\n", "## [Unreleased]\n\n## [v1.8.1] - 2026-11-12\n", 1)
        result, text = self.notes("1.8.1", "--fallback", "none", "--notes-from", "1.8.0", changelog=finalized)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Something new.", text)
        self.assertNotIn("Notes fallback", text)

    def test_reuse_must_name_an_older_version_that_has_notes(self):
        for source, message in (("1.8.1", "must be older"), ("1.7.9", "Missing CHANGELOG section for version: 1.7.9")):
            with self.subTest(source=source):
                result, _ = self.notes("1.8.1", "--fallback", "none", "--notes-from", source)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


class ReleaseTagMarkerTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.repo = Path(self.folder.name)

        def git(*args):
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "tag.gpgSign=false",
                            "-c", "commit.gpgSign=false", *args], cwd=self.repo, check=True, capture_output=True)
        self.git = git
        git("init", "-q")
        git("commit", "-q", "--allow-empty", "-m", "Fix\n\nRelease-Notes-From: v1.0.0")

    def marker(self, tag):
        return subprocess.run([str(NOTES_FROM), tag], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()

    def test_annotated_tag_with_the_marker_names_the_version(self):
        self.git("tag", "-a", "v1.8.1", "-m", "Release v1.8.1\n\nRelease-Notes-From: v1.8.0")
        self.assertEqual(self.marker("v1.8.1"), "1.8.0")

    def test_annotated_tag_without_the_marker_names_nothing(self):
        self.git("tag", "-a", "v2.0.0", "-m", "Release v2.0.0")
        self.assertEqual(self.marker("v2.0.0"), "")

    def test_a_lightweight_tag_cannot_borrow_the_marker_from_a_commit(self):
        self.git("tag", "v2.0.1")
        self.assertEqual(self.marker("v2.0.1"), "")

    def test_a_missing_tag_names_nothing(self):
        self.assertEqual(self.marker("v9.9.9"), "")

    def test_release_script_writes_the_marker_only_when_it_reuses_notes(self):
        text = RELEASE.read_text()
        block = text[text.index('RELEASE_NOTES="Release $TAG_NAME"'):text.index("# --- Commit, tag, and push ---")]
        self.assertIn('if [[ "$RELEASE_NOTES_SOURCE_VERSION" != "$VERSION" ]]; then', block)
        self.assertIn("Release-Notes-From: v$RELEASE_NOTES_SOURCE_VERSION", block)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_production_checks_the_section_before_building(self):
        text = WORKFLOW.read_text()
        check = text.index("- name: Check the changelog has this release's section")
        self.assertLess(check, text.index("- name: Build - IDBKit frameworks"))
        self.assertLess(check, text.index("- name: Notarize - Submit to Apple for notarization"))
        step = text[check:text.index("- name:", check + 1)]
        self.assertIn("if: steps.context.outputs.notesMode == 'changelog'", step)
        self.assertIn('scripts/release-notes-from.sh "$TAG"', step)
        self.assertIn("--fallback none", step)
        self.assertIn('${NOTES_FROM:+--notes-from "$NOTES_FROM"}', step)

    def test_published_notes_never_fall_back_on_their_own(self):
        text = WORKFLOW.read_text()
        self.assertNotIn("newest-older", text)
        step = text[text.index("- name: Generate release notes"):text.index("- name: Upload build artifacts")]
        self.assertIn('NOTES_FROM="${{ steps.notes_source.outputs.notes_from }}"', step)
        self.assertIn("--fallback none", step)


if __name__ == "__main__":
    unittest.main()
