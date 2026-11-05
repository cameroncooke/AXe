"""Recognize public screenshot receipts without reading or changing an app."""
import unittest

from transcript import Call, classify, returned_paths


class PlainScreenshotTests(unittest.TestCase):
    def test_ansi_success_receipt_authorizes_png(self):
        call = Call(1, "id", "Bash", "/candidate/flowdeck ui simulator screen --screenshot --simulator device", {}, 1,
                    text="\x1b[38;2;100;200;100m✓\x1b[0m Screen captured\n   Screenshot: /run/image.png\n   Elements: 1\n   Size: 1206x2622 px")
        classify(call, "flowdeck", [])
        self.assertEqual(returned_paths(call), {"/run/image.png"})

    def test_arbitrary_paths_and_failed_capture_are_not_authorized(self):
        for text, error in (("Screenshot: /run/image.png", False), ("✓ Screen captured\n Screenshot: /source/app.swift", False), ("✓ Screen captured\n Screenshot: /run/image.png", True)):
            call = Call(1, "id", "Bash", "/candidate/flowdeck ui simulator screen --screenshot --simulator device", {}, 1, text=text, error=error)
            classify(call, "flowdeck", [])
            self.assertEqual(returned_paths(call), set())


if __name__ == "__main__":
    unittest.main()
