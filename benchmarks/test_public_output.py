"""Public help and screenshot artifact provenance checks; no live tool calls."""

import json
from pathlib import Path
import tempfile
import unittest

from transcript import Call, classify, read_transcript, returned_paths


class PublicOutputTests(unittest.TestCase):
    def test_nested_screenshot_path_decodes_json_slashes(self):
        call = Call(1, "id", "Bash", "/candidate/flowdeck ui simulator screen --screenshot --json --simulator device", {}, 1,
                    text=r'{"schema":"flowdeck.ui","screenshot":{"captured":true,"path":"\/run\/image.png"}}')
        classify(call, "flowdeck", [])
        self.assertEqual(returned_paths(call), {"/run/image.png"})

    def test_uncaptured_screenshot_and_unrelated_paths_are_not_authorized(self):
        for reply in ({"screenshot": {"captured": False, "path": "/source/app.swift"}}, {"app": {"path": "/source/app.swift"}}):
            call = Call(1, "id", "Bash", "/candidate/flowdeck ui simulator screen --json --simulator device", {}, 1, text=json.dumps(reply))
            classify(call, "flowdeck", [])
            self.assertEqual(returned_paths(call), set())

    def test_examples_are_help_without_device_requirement(self):
        for flag in ("--examples", "-e"):
            call = Call(1, "id", "Bash", "/candidate/flowdeck ui simulator batch " + flag, {}, 1)
            classify(call, "flowdeck", [])
            self.assertEqual(call.category, "help")
            self.assertFalse(call.requires_device)
            self.assertFalse(call.actions)

    def test_public_find_is_a_ui_read_even_when_it_fails(self):
        call = Call(1, "id", "Bash", '/candidate/flowdeck ui simulator find "target" --simulator device --json', {}, 1,
                    text='{"schema":"flowdeck.ui","success":false,"type":"ui_find"}')
        classify(call, "flowdeck", [])
        self.assertEqual(call.category, "ui")
        self.assertTrue(call.requires_device)
        self.assertFalse(call.actions)

    def test_read_is_authorized_by_earlier_nested_screenshot_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = str(root / "image.png")
            blocks = [
                {"type": "tool_use", "id": "1", "name": "Bash", "input": {"command": "/candidate/flowdeck ui simulator screen --json --screenshot --simulator device"}},
                {"type": "tool_result", "tool_use_id": "1", "content": json.dumps({"schema": "flowdeck.ui", "screenshot": {"captured": True, "path": target}})},
                {"type": "tool_use", "id": "2", "name": "Read", "input": {"file_path": target}},
                {"type": "tool_result", "tool_use_id": "2", "content": [{"type": "image", "source": {"type": "base64", "data": "aW1hZ2U="}}]},
            ]
            transcript = root / "claude.jsonl"
            transcript.write_text("\n".join(json.dumps({"message": {"content": [block]}}) for block in blocks))
            calls, errors = read_transcript(transcript, "flowdeck", root)
            self.assertFalse(errors)
            self.assertEqual(calls[1].category, "image")
            self.assertEqual(calls[1].image_count, 1)
            self.assertEqual(calls[1].image_bytes, 5)
            self.assertFalse(calls[1].captures)


if __name__ == "__main__":
    unittest.main()
