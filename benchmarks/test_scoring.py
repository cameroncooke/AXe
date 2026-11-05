"""Offline evidence checks. These fixtures do not claim live app success."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scoring import complete_views, contacts, identity_checks, reminders, score_run, weather
from transcript import Action, Call, Capture, Node, captures, classify, observed_runtime, read_transcript, split_row, text_content


def capture(number, *nodes, complete=True, identity=""):
    return Capture(number, number * 2, list(nodes), identity, complete)


def state(result, identity):
    return next(item["status"] for item in result if item["id"] == identity)


def input_call(number, kind, label="", value="", executed=True):
    call = Call(number, str(number), "Bash", "", {}, number * 2 - 1, category="ui")
    call.actions = [Action(kind, label, value, executed)]
    return call


class ScoringTests(unittest.TestCase):
    def test_final_claim_and_completed_flag_are_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "claude.jsonl").write_text(json.dumps({"message": {"content": [{"type": "text", "text": "All tasks completed perfectly."}]}}) + "\n")
            (root / "result.json").write_text(json.dumps({"completed": True, "run": {"claudeExitCode": 0, "parserExitCode": 0, "wallClockSeconds": 1}}))
            with patch("scoring.token_totals", return_value={"returnedTextTokens": 0, "tokenStatus": "measured"}):
                result = score_run(root, "weather", "axe")
            self.assertEqual(result["status"], "unverified")
            self.assertEqual(result["metrics"]["totalCalls"], 0)

    def test_later_wrong_setting_overrides_earlier_success(self):
        first = capture(1, Node("1", "button", "m/s", "selected", selected=True))
        second = capture(2, Node("1", "button", "m/s", "not selected"))
        self.assertEqual(state(weather([], [first, second]), "settings.m/s"), "failed")

    def test_weather_input_after_details_is_failure(self):
        detail = capture(1, Node("1", "text", "PRECIPITATION"), Node("2", "text", "chance over the next 24 hours"))
        checks = weather([input_call(2, "tap", "Back")], [detail])
        self.assertEqual(state(checks, "procedure.noInputAfterDetails"), "failed")

    def test_weather_batch_cannot_hide_input_after_detail_entry(self):
        detail = capture(2, Node("1", "text", "PRECIPITATION"), Node("2", "text", "chance over the next 24 hours"))
        batch = input_call(2, "tap", "PRECIP., 78%, Next 24 hours")
        batch.actions.append(Action("type", value="forbidden", executed=True))
        self.assertEqual(state(weather([batch], [detail]), "procedure.noInputAfterDetails"), "failed")

    def test_weather_unlabelled_batch_has_no_proven_entry_boundary(self):
        detail = capture(2, Node("1", "text", "PRECIPITATION"), Node("2", "text", "chance over the next 24 hours"))
        batch = input_call(2, "tap")
        batch.actions.append(Action("tap", executed=True))
        self.assertEqual(state(weather([batch], [detail]), "procedure.noInputAfterDetails"), "unverified")

    def test_rejected_zero_input_does_not_break_read_only_rule(self):
        detail = capture(1, Node("1", "text", "PRECIPITATION"), Node("2", "text", "chance over the next 24 hours"))
        checks = weather([input_call(2, "tap", "Back", executed=False)], [detail])
        self.assertEqual(state(checks, "procedure.noInputAfterDetails"), "passed")

    def test_contacts_edit_after_saved_card_is_failure(self):
        editor = capture(1, Node("1", "text-field", "First name", "MCP"), Node("2", "text-field", "Last name", "Contact Benchmark"))
        card = capture(2, Node("1", "button", "Edit"), Node("2", "text", "MCP Contact Benchmark"))
        checks = contacts([input_call(2, "tap", "Done"), input_call(3, "tap", "Edit")], [editor, card])
        self.assertEqual(state(checks, "procedure.noEditAfterSave"), "failed")

    def test_contacts_save_boundary_precedes_first_saved_observation(self):
        editor = capture(1, Node("1", "text-field", "First name", "MCP"), Node("2", "text-field", "Last name", "Contact Benchmark"))
        card = capture(5, Node("1", "button", "Edit"), Node("2", "text", "MCP Contact Benchmark"))
        checks = contacts([input_call(2, "tap", "Done"), input_call(3, "tap", "Edit")], [editor, card])
        self.assertEqual(state(checks, "procedure.noEditAfterSave"), "failed")

    def test_contacts_batch_cannot_hide_edit_after_done(self):
        editor = capture(1, Node("1", "text-field", "First name", "MCP"), Node("2", "text-field", "Last name", "Contact Benchmark"))
        batch = input_call(2, "tap", "Done")
        batch.actions.append(Action("tap", "Edit", executed=True))
        self.assertEqual(state(contacts([batch], [editor]), "procedure.noEditAfterSave"), "failed")

    def test_contacts_editor_only_cannot_prove_saved_values(self):
        editor = capture(1, Node("1", "text-field", "First name", "MCP"), Node("2", "text-field", "Last name", "Contact Benchmark"), Node("3", "text", "mcp.contact.benchmark@example.com"))
        self.assertEqual(state(contacts([], [editor]), "saved.email"), "unverified")

    def test_duplicate_reminder_cannot_be_hidden_by_dictionary(self):
        nodes = [Node("0", "heading", "MCP Benchmark List"), Node("1", "other", "Buy milk benchmark, Completed"), Node("2", "other", "Call team benchmark, Completed"), Node("3", "other", "File report benchmark, Incomplete")]
        self.assertEqual(state(reminders([], [capture(1, *nodes)]), "list.exactlyThreeStates"), "passed")
        nodes.append(Node("4", "other", "Buy milk benchmark, Completed"))
        self.assertEqual(state(reminders([], [capture(1, *nodes)]), "list.exactlyThreeStates"), "failed")

    def test_partial_and_different_snapshots_are_not_combined(self):
        a = capture(1, Node("1", "text", "First"), complete=False, identity="a")
        b = capture(2, Node("2", "text", "Second"), identity="b")
        self.assertEqual([n.label for n in complete_views([a, b])[0].nodes], ["Second"])
        b.identity = "a"
        self.assertEqual([n.label for n in complete_views([a, b])[0].nodes], ["First", "Second"])
        a.complete = True
        self.assertEqual([n.label for n in complete_views([a, b])[-1].nodes], ["Second"])

    def test_stale_capture_and_rocket_disappeared_rows_are_not_proof(self):
        stale = {"schema": "axe.output.agent-result", "data": {"cache": {"requiresRefresh": True}, "capture": {"rows": ["e1|tap|button|Done|"]}}}
        self.assertEqual(captures(stale, 1, 2), [])
        self.assertEqual(captures({"rs": "1", "data": {"disappeared": ["1|button|Done||enabled"]}}, 1, 2), [])

    def test_batch_partial_receipt_does_not_assume_all_steps_ran(self):
        command = "axe batch --agent --steps-json '{\"steps\":[{\"action\":\"tap\",\"ref\":\"e1\"},{\"action\":\"tap\",\"ref\":\"e2\"}]}'"
        call = Call(1, "id", "Bash", command, {}, 1, text=json.dumps({"schema": "axe.output.agent-result", "didError": True, "data": {"batch": {"completedSteps": 1}}}))
        classify(call, "axe", [Node("e1", "button", "First"), Node("e2", "button", "Second")])
        self.assertEqual([(a.label, a.executed) for a in call.actions], [("First", True), ("Second", False)])
        reply = json.loads(call.text)
        reply["data"]["batch"]["steps"] = [{"index": 1, "receipt": {"enqueuedEventCount": 2}}, {"index": 2, "receipt": {"enqueuedEventCount": 0}}]
        call.text = json.dumps(reply)
        call.actions = []
        classify(call, "axe", [Node("e1", "button", "First"), Node("e2", "button", "Second")])
        self.assertTrue(call.actions[0].executed)
        self.assertFalse(call.actions[1].executed)
        reply["data"]["batch"]["steps"][1]["receipt"]["enqueuedEventCount"] = 1
        call.text = json.dumps(reply)
        call.actions = []
        classify(call, "axe", [Node("e1", "button", "First"), Node("e2", "button", "Second")])
        self.assertTrue(call.actions[1].executed)

    def test_rs1_escaped_pipe_and_backslash(self):
        self.assertEqual(split_row(r"e1|text|A\|B|C\\|D"), ["e1", "text", "A|B", "C\\", "D"])

    def test_exact_text_excludes_image_data_and_keeps_errors(self):
        self.assertEqual(text_content([{"type": "text", "text": "Exit code 1\nerror"}, {"type": "image", "source": {"data": "not text"}}, {"type": "text", "text": "tail"}]), "Exit code 1\nerror\ntail")

    def test_missing_result_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "claude.jsonl"
            file.write_text(json.dumps({"message": {"content": [{"type": "tool_use", "id": "missing", "name": "Bash", "input": {"command": "axe describe-ui --agent"}}]}}) + "\n")
            calls, errors = read_transcript(file, "axe")
        self.assertEqual(len(calls), 1)
        self.assertIn("Missing result", errors[0])

    def test_other_tool_or_shell_chain_requires_review(self):
        for command in ("rocketsim elements --agent", "axe describe-ui --agent; echo fake", "axe describe-ui --agent\naxe tap --ref e1", "axe describe-ui --udid $(other-command)", 'axe type "text"\naxe tap --ref e1', "axe type 'text'; axe tap --ref e1", 'axe type "quoted\\\" text"\naxe tap --ref e1', 'axe type "line\ntext" && axe tap --ref e1', 'axe type "line\n$(axe tap --ref e1)"'):
            call = Call(1, "id", "Bash", command, {}, 1)
            classify(call, "axe", [])
            self.assertEqual(call.category, "unknown")

    def test_quoted_multiline_text_stays_one_input_call(self):
        for quoted, wanted in (("'\nFile report benchmark'", "\nFile report benchmark"), ('"\nCall team benchmark"', "\nCall team benchmark"), ('"\n"', "\n"), ('"quoted\\\"\ntext"', 'quoted"\ntext')):
            call = Call(1, "id", "Bash", "axe type " + quoted + " --agent --udid device", {}, 1)
            classify(call, "axe", [])
            self.assertEqual(call.category, "ui")
            self.assertEqual(len(call.actions), 1)
            self.assertEqual(call.actions[0].value, wanted)

    def test_candidate_and_simulator_are_bound_to_every_call(self):
        call = Call(1, "id", "Bash", "/candidate/axe describe-ui --agent --udid wanted", {}, 1)
        classify(call, "axe", [])
        self.assertEqual(state(identity_checks([call], "/candidate/axe", "wanted"), "identity.candidate"), "passed")
        self.assertEqual(state(identity_checks([call], "/other/axe", "wanted"), "identity.candidate"), "failed")
        self.assertEqual(state(identity_checks([call], "/candidate/axe", "other"), "identity.simulator"), "failed")
        call.command = "axe describe-ui --agent"
        classify(call, "axe", [])
        self.assertEqual(state(identity_checks([call], "/candidate/axe", "wanted"), "identity.candidate"), "unverified")
        self.assertEqual(state(identity_checks([call], "/candidate/axe", "wanted"), "identity.simulator"), "unverified")

    def test_runtime_uses_init_not_final_claim_or_requested_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = [{"type": "system", "subtype": "init", "model": "exact-model", "claude_code_version": "2.3.4"}, {"type": "assistant", "message": {"model": "exact-model", "content": [{"type": "text", "text": "Model is another-model"}]}}]
            (root / "claude.jsonl").write_text("\n".join(json.dumps(event) for event in events))
            observed = observed_runtime(root)
            self.assertEqual(observed["model"], "exact-model")
            self.assertEqual(observed["claudeVersion"], "2.3.4")


if __name__ == "__main__":
    unittest.main()
