"""Grading of each tool's own documented surface, so no tool is marked down for using it.

Offline: no model, tool or simulator calls."""
import json
from pathlib import Path
import unittest

from scoring import contacts, setup_checks
from transcript import Call, Capture, Node, classify, returned_paths

UDID = "11111111-2222-3333-4444-555555555555"


def call(command, tool, text="", previous=(), error=False, run_directory=None, number=1):
    value = Call(number, str(number), "Bash", command, {}, number, result_line=number + 1, text=text, error=error)
    classify(value, tool, list(previous), run_directory=run_directory)
    return value


class FairGradingTests(unittest.TestCase):
    def test_flowdeck_documented_verbs_are_ui_calls(self):
        rocket = call("/x/rocketsim do --step 'interact focus --id 86 --screen latest' --step 'interact type London' --udid " + UDID,
                      "rocketsim", text=json.dumps({"rs": "1", "ok": True, "data": {"steps": [
                          {"kind": "interact", "result": {}}, {"kind": "interact", "result": {}}]}}))
        self.assertEqual(rocket.category, "ui")
        self.assertEqual([(a.kind, a.value) for a in rocket.actions], [("focus", ""), ("type", "London")])
        for verb, kind in (("hide-keyboard", "hide-keyboard"), ("double-tap", "double-tap"), ("back", "back"),
                           ("erase", "erase"), ("assert", None), ("session", None)):
            with self.subTest(verb=verb):
                value = call("/x/flowdeck ui simulator " + verb + " --simulator " + UDID, "flowdeck", text="{}")
                self.assertEqual(value.category, "ui")
                self.assertEqual(value.device, UDID)
                self.assertEqual([a.kind for a in value.actions], [kind] if kind else [])

    def test_help_subcommands_count_as_help(self):
        self.assertEqual(call("/x/flowdeck help ui simulator swipe", "flowdeck").category, "help")
        self.assertEqual(call("/x/rocketsim help interact", "rocketsim").category, "help")

    def test_flowdeck_tap_uses_the_control_the_tool_reports(self):
        # FlowDeck 1.34.0 numbers interactive-elements refs differently from what tap resolves.
        earlier = [Node("e1", "button", "Settings"), Node("e9", "button", "San Francisco")]
        value = call("/x/flowdeck ui simulator tap --ref e1 --simulator " + UDID, "flowdeck",
                     text="✓ Tapped ref e1: San Francisco\n", previous=earlier)
        self.assertEqual(value.actions[0].label, "San Francisco")
        self.assertEqual(value.actions[0].role, "button")
        # Without a receipt the earlier capture still names the target.
        plain = call("/x/flowdeck ui simulator tap --ref e1 --simulator " + UDID, "flowdeck", text="{}", previous=earlier)
        self.assertEqual(plain.actions[0].label, "Settings")

    def test_flowdeck_batch_targets_and_per_step_success(self):
        earlier = [Node("e3", "button", "Add", identifier="add_button")]
        steps = [{"action": "tap", "target": "Settings"}, {"action": "tap", "target": "add_button", "by_id": True},
                 {"action": "type", "text": "London"}]
        reply = json.dumps({"steps": [{"success": True}, {"success": False}]})
        value = call("/x/flowdeck ui simulator batch --simulator " + UDID + " --steps " + json.dumps(json.dumps(steps)),
                     "flowdeck", text=reply, previous=earlier)
        self.assertEqual([(a.kind, a.label, a.executed) for a in value.actions],
                         [("tap", "Settings", True), ("tap", "Add", False), ("type", "", None)])

    def test_any_tool_may_write_a_read_once_to_a_run_file(self):
        for tool, command in (("rocketsim", "/x/rocketsim elements --agent --udid " + UDID),
                              ("rocketsim", "/x/rocketsim snapshot --udid " + UDID),
                              ("flowdeck", "/x/flowdeck ui simulator screen --json --simulator " + UDID),
                              ("axe", "/x/axe describe-ui --agent --udid " + UDID)):
            image = "snapshot" in command
            for target, wanted in (("/run/a." + ("png" if image else "json"), "ui"),
                                   ("/outside/a." + ("png" if image else "json"), "unknown"),
                                   ("/tmp/rs-snap." + ("png" if image else "json"), "ui"),
                                   ("/run/a." + ("json" if image else "swift"), "unknown")):
                with self.subTest(command=command, target=target):
                    value = call(command + " > " + target, tool, run_directory="/run")
                    self.assertEqual(value.category, wanted)
                    if wanted == "ui":
                        self.assertIn(str(Path(target).resolve()), returned_paths(value))

    def test_flowdeck_session_and_batch_files_authorize_reads(self):
        session = call("/x/flowdeck ui simulator session start --simulator " + UDID + " --json", "flowdeck",
                       text=json.dumps({"latest_tree": "/s/latest-tree.json",
                                        "latest_interactive_tree": "/s/latest-interactive.json",
                                        "latest_screenshot": "/s/latest.png"}))
        self.assertEqual(returned_paths(session), {"/s/latest-tree.json", "/s/latest-interactive.json", "/s/latest.png"})
        batch = call("/x/flowdeck ui simulator batch --screenshot --simulator " + UDID + " --steps '[]'", "flowdeck",
                     text="✓ Batch: 3 steps\n   Screenshot: /s/final.png\n")
        self.assertIn("/s/final.png", returned_paths(batch))

    def test_ui_only_runs_fail_if_the_agent_builds_or_launches(self):
        expected = {"launchedByHarness": True}
        clean = [call("/x/axe describe-ui --agent --udid " + UDID, "axe", text="{}")]
        self.assertEqual(setup_checks(clean, "weather", expected)[0]["status"], "passed")
        launch = call("/usr/bin/xcrun simctl launch " + UDID + " app.weather", "axe", text="app.weather: 4", number=2)
        result = setup_checks(clean + [launch], "weather", expected)[0]
        self.assertEqual((result["id"], result["status"]), ("setup.byHarness", "failed"))

    def test_tapping_the_editor_title_is_not_a_second_add(self):
        editor = [Node("e45", "heading", "New Contact"), Node("e7", "button", "Done")]
        tap_title = call("/x/rocketsim interact tap --id e45 --udid " + UDID, "rocketsim",
                         text=json.dumps({"rs": "1", "ok": True}), previous=editor)
        self.assertEqual((tap_title.actions[0].label, tap_title.actions[0].role), ("New Contact", "heading"))
        add = call("/x/rocketsim interact tap --label Add --udid " + UDID, "rocketsim",
                   text=json.dumps({"rs": "1", "ok": True}), number=2)
        rows = [r for r in contacts([add, tap_title], []) if r["id"] == "creation.oneContact"][0]
        self.assertEqual([e["target"] for e in rows["evidence"]], ["Add"])


if __name__ == "__main__":
    unittest.main()
