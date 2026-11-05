"""Equivalent public control and response formats across simulator CLIs."""
import unittest

from scoring import fact_nodes, weather
from transcript import Call, Capture, Node, captures, json_output, read_output, returned_paths


class ResponseFormatTests(unittest.TestCase):
    def test_combined_accessibility_label_requires_exact_components(self):
        capture = Capture(1, 2, [Node("1", "button", "Heading, 78%, Additional detail")])
        self.assertEqual(len(fact_nodes(capture, ("Heading", "78%"))), 1)
        self.assertFalse(fact_nodes(capture, ("Heading", "8%")))
        self.assertFalse(fact_nodes(capture, ("Heading", "77%")))

    def test_checkbox_and_switch_states_use_same_boolean_rule(self):
        for role in ("switch", "checkbox"):
            capture = Capture(1, 2, [Node("1", role, "Atmospheric animations", "0"),
                                     Node("2", role, "Severe weather alerts", "0"),
                                     Node("3", role, "Reduce transparency", "1")])
            checks = {check["id"]: check["status"] for check in weather([], [capture])}
            for label in ("Atmospheric animations", "Severe weather alerts", "Reduce transparency"):
                self.assertEqual(checks["settings." + label], "passed")
            capture.nodes[0].value = "1"
            checks = {check["id"]: check["status"] for check in weather([], [capture])}
            self.assertEqual(checks["settings.Atmospheric animations"], "failed")

    def test_batch_final_capture_replaces_earlier_unit_state(self):
        initial = Capture(1, 2, [Node("1", "button", "°C", "not selected")])
        reply = {"schema": "flowdeck.ui", "final": {"schema": "flowdeck.ui", "accessibility": {"tree": [{"ref": "1", "role": "Button", "label": "°C", "value": "selected"}]}}}
        final = captures(reply, 2, 4)
        self.assertEqual(final[0].nodes[0].value, "selected")
        checks = {check["id"]: check["status"] for check in weather([], [initial] + final)}
        self.assertEqual(checks["settings.°C"], "passed")

    def test_inline_persisted_header_authorizes_only_header_path(self):
        call = Call(1, "id", "Bash", "", {}, 1, text="<persisted-output>\nOutput too large (34KB). Full output saved to: /public/real.txt\n\nPreview (first 2KB):\nFull output saved to: /source/not-an-artifact.txt\n</persisted-output>")
        self.assertEqual(returned_paths(call), {"/public/real.txt"})

    def test_read_arrow_and_tab_prefixes_preserve_same_json(self):
        for separator in ("→", "\t"):
            value = read_output("1" + separator + '{\n2' + separator + ' "success": true\n3' + separator + '}')
            self.assertEqual(json_output(value), {"success": True})


if __name__ == "__main__":
    unittest.main()
