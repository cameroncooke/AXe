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

    def test_flowdeck_session_tree_reads_are_evidence_dated_to_the_read(self):
        import tempfile
        from transcript import read_transcript
        tree = [{"role": "Button", "label": "Settings", "id": "weather.settingsButton", "visible": True, "children": []}]
        lines = [
            {"cwd": "/work"},
            {"message": {"content": [{"type": "tool_use", "id": "1", "name": "Bash", "input": {
                "command": "/x/flowdeck ui simulator session start -S " + UDID + " --json"}}]}},
            {"message": {"content": [{"type": "tool_result", "tool_use_id": "1", "content": json.dumps({
                "latest_tree": "/s/latest-tree.json", "latest_interactive_tree": "/s/latest-interactive-tree.json",
                "latest_screenshot": "/s/latest.jpg"})}]}},
            {"message": {"content": [{"type": "tool_use", "id": "2", "name": "Bash", "input": {
                "command": "/x/flowdeck ui simulator tap Settings -S " + UDID + " --no-screen"}}]}},
            {"message": {"content": [{"type": "tool_result", "tool_use_id": "2", "content": "✓ Tapped Settings"}]}},
            {"message": {"content": [{"type": "tool_use", "id": "3", "name": "Read", "input": {
                "file_path": "/s/latest-tree.json"}}]}},
            {"message": {"content": [{"type": "tool_result", "tool_use_id": "3", "content": "1\t" + json.dumps(tree)}]}},
            {"message": {"content": [{"type": "tool_use", "id": "4", "name": "Bash", "input": {
                "command": "/x/flowdeck ui simulator screen -S " + UDID + " --output /s/shot.png"}}]}},
            {"message": {"content": [{"type": "tool_result", "tool_use_id": "4", "content":
                "✓ Screen captured\n   Screenshot: /s/shot.png\n   Elements: 3"}]}},
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as handle:
            handle.write("\n".join(json.dumps(line) for line in lines))
        calls, errors = read_transcript(handle.name, "flowdeck")
        self.assertEqual(errors, [])
        read = calls[2]
        self.assertEqual((read.category, read.evidence_call), ("publicOutput", 3))
        self.assertEqual([n.label for n in read.captures[0].nodes], ["Settings"])
        self.assertEqual(read.captures[0].call, 3)
        self.assertIn(str(Path("/s/shot.png").resolve()), returned_paths(calls[3]))

    def test_ui_only_runs_fail_if_the_agent_builds_or_launches(self):
        expected = {"launchedByHarness": True}
        clean = [call("/x/axe describe-ui --agent --udid " + UDID, "axe", text="{}")]
        self.assertEqual(setup_checks(clean, "weather", expected)[0]["status"], "passed")
        launch = call("/usr/bin/xcrun simctl launch " + UDID + " app.weather", "axe", text="app.weather: 4", number=2)
        result = setup_checks(clean + [launch], "weather", expected)[0]
        self.assertEqual((result["id"], result["status"]), ("setup.byHarness", "failed"))

    def test_saved_email_row_may_carry_its_type_like_the_phone_row(self):
        from scoring import contacts as grade
        import inspect
        source = inspect.getsource(grade)
        self.assertIn("mcp\\.contact\\.benchmark@example\\.com", source)
        import re
        pattern = r"[^,]{1,24}, mcp\.contact\.benchmark@example\.com"
        self.assertIsNotNone(re.fullmatch(pattern, "home, mcp.contact.benchmark@example.com"))
        self.assertIsNone(re.fullmatch(pattern, "home, mcp.contact.benchmark@example.com.evil"))
        self.assertIsNone(re.fullmatch(pattern, "Email, other text, mcp.contact.benchmark@example.com"))

    def test_rocketsim_nav_rows_are_evidence(self):
        from transcript import captures
        value = {"rs": "1", "ok": True, "data": {"mode": "nav", "screen": "b6e7c093", "seq": 626,
                 "rows": ["13|button|mobile, 55 5010 4242", "17|button|home, mcp.contact.benchmark@example.com"]}}
        nodes = captures(value, 35, 1)[0].nodes
        self.assertEqual([(n.ref, n.role, n.label, n.value) for n in nodes],
                         [("13", "button", "mobile, 55 5010 4242", ""),
                          ("17", "button", "home, mcp.contact.benchmark@example.com", "")])
        self.assertFalse(any(n.value_known for n in nodes))
        # A later labels-only read does not hide the last value actually shown.
        from scoring import latest_state, matches
        typed = Capture(10, 1, [Node("e3", "textfield", "First name", "MCP")])
        later = Capture(20, 2, [Node("4", "textfield", "First name", "", value_known=False)])
        result = latest_state([typed, later], "contact.First name", lambda c: matches(c, "First name"),
                              lambda n: n.value == "MCP")
        self.assertEqual(result["status"], "passed")

    def test_rocketsim_text_snapshot_inside_do_is_evidence(self):
        from transcript import captures
        text = ("rs/1 act screen=998bffb2 seq=209 count=3\n5|staticText|2 Completed||enabled\n"
                "8|group|File report benchmark, Incomplete||enabled\n11|group|Buy milk benchmark, Completed||enabled\n"
                "!actions|8|Delete")
        value = {"rs": "1", "ok": True, "data": {"steps": [{"kind": "interact", "result": {"screen_changed": True}},
                                                           {"kind": "elements", "result": text}]}}
        found = captures(value, 19, 1)
        self.assertEqual([n.label for n in found[0].nodes],
                         ["2 Completed", "File report benchmark, Incomplete", "Buy milk benchmark, Completed"])
        self.assertEqual(found[0].identity, "998bffb2:209")

    def test_a_setting_tapped_after_its_last_read_is_unverified_not_failed(self):
        from scoring import weather
        off = Capture(6, 1, [Node("", "checkbox", "Reduce transparency", "0")])
        read = call("/x/flowdeck ui simulator screen -S " + UDID + " --json", "flowdeck", text="{}", number=6)
        tap = call("/x/flowdeck ui simulator tap 'Reduce transparency' -S " + UDID + " --no-screen", "flowdeck",
                   text="✓ Tapped Reduce transparency", number=8)
        row = [r for r in weather([read, tap], [off]) if r["id"] == "settings.Reduce transparency"][0]
        self.assertEqual(row["status"], "unverified")
        # Without a later tap the stale observation still fails.
        row = [r for r in weather([read], [off]) if r["id"] == "settings.Reduce transparency"][0]
        self.assertEqual(row["status"], "failed")

    def test_detail_entry_is_the_action_whose_own_reply_shows_the_details(self):
        from scoring import detail_entry
        before = Capture(33, 1, [Node("e1", "button", "London")])
        details = Capture(38, 2, [Node("e5", "statictext", "PRECIPITATION")])
        scroll = call("/x/flowdeck ui simulator scroll -S " + UDID + " --no-screen", "flowdeck", text="✓", number=36)
        tap = call("/x/flowdeck ui simulator tap --point 100,570 -S " + UDID + " --json", "flowdeck", text="{}", number=38)
        self.assertEqual(detail_entry([scroll, tap], [before, details], 38), (38, 0))
        # Two unlabelled actions before a separate read still cannot place the boundary.
        read = Capture(39, 3, details.nodes)
        self.assertIsNone(detail_entry([scroll, tap], [before, read], 39))

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
