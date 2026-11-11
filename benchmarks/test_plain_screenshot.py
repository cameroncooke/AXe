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


    def test_axe_saved_receipt_authorizes_the_requested_png_only(self):
        command = "/candidate/axe screenshot --udid device --output /run/state.png"
        for text, error, expected in (
                ("Screenshot saved to /run/state.png\n/run/state.png", False, {"/run/state.png"}),
                ("Screenshot saved to /run/other.png\n/run/other.png", False, set()),
                ("Screenshot saved to /run/state.png\n/run/state.png", True, set())):
            call = Call(1, "id", "Bash", command, {}, 1, text=text, error=error)
            classify(call, "axe", [])
            self.assertEqual(returned_paths(call), expected)
        call = Call(1, "id", "Bash", "/candidate/axe screenshot --udid device --output /source/app.swift", {}, 1,
                    text="Screenshot saved to /source/app.swift\n/source/app.swift")
        classify(call, "axe", [])
        self.assertEqual(returned_paths(call), set())

if __name__ == "__main__":
    unittest.main()
