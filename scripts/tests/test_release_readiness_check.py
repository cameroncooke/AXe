import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-release-readiness.py"
spec = importlib.util.spec_from_file_location("check_release_readiness", SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

LOG = """# Log

## Phase 1: audits

- [x] Read the code. It was long.
- Not an item: [ ] in the middle of a line

## Phase 2: fixes

- [ ] SEL-17. Fold the ordinary route into the selected route. Not started.
  - [~] A nested item that is under way
- [!] Devices unreachable
- [x] Done item
"""


class ReleaseReadinessCheckTests(unittest.TestCase):
    def test_open_items_are_listed_under_their_section(self):
        self.assertEqual(check.open_items(LOG), [
            ("Phase 2: fixes", "not started", "SEL-17. Fold the ordinary route into the selected route. Not started"),
            ("Phase 2: fixes", "in progress", "A nested item that is under way"),
            ("Phase 2: fixes", "blocked", "Devices unreachable"),
        ])

    def test_a_long_item_is_cut_at_a_word(self):
        text = "word " * 40
        self.assertEqual(check.shortened(text), ("word " * 20).strip() + "…")
        self.assertEqual(check.shortened("Short item."), "Short item")

    def test_a_log_with_only_done_items_has_none(self):
        self.assertEqual(check.open_items("## Phase 1\n\n- [x] Done\n- plain line\n"), [])

    def test_exit_status_follows_the_open_items(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "log.md"
            path.write_text(LOG)
            failed = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True)
            self.assertEqual(failed.returncode, 1)
            self.assertIn("3 open items", failed.stdout)
            self.assertIn("not started: SEL-17. Fold the ordinary route", failed.stdout)
            path.write_text("## Phase 1\n\n- [x] Done\n")
            passed = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True)
            self.assertEqual(passed.returncode, 0)
            self.assertIn("no open items", passed.stdout)
            missing = subprocess.run([sys.executable, str(SCRIPT), str(path) + ".none"], capture_output=True, text=True)
            self.assertEqual(missing.returncode, 2)


if __name__ == "__main__":
    unittest.main()
