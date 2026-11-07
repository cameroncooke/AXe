"""Recorded setup and public CLI payload contracts; no simulator or network."""

import json
from pathlib import Path
import tempfile
import unittest

from scoring import identity_checks, setup_checks
from transcript import Call, Node, classify, read_transcript


UDID = "11111111-2222-3333-4444-555555555555"


def statuses(checks):
    return {row["id"]: row["status"] for row in checks}


def events(name, arguments, content, number):
    return [{"message": {"content": [{"type": "tool_use", "id": str(number), "name": name, "input": arguments}]}},
            {"message": {"content": [{"type": "tool_result", "tool_use_id": str(number), "content": content}]}}]


class ContractTests(unittest.TestCase):
    def setup_calls(self):
        expected = {"project": "/source/Weather.xcodeproj", "scheme": "Weather", "bundleId": "app.weather", "developerDir": "/Xcode/Developer", "udid": UDID, "runDirectory": "/run"}
        commands = ["/Xcode/Developer/usr/bin/xcodebuild -project /source/Weather.xcodeproj -scheme Weather -configuration Debug -sdk iphonesimulator -destination id=" + UDID + " -derivedDataPath /run/DerivedData -jobs 1 build",
                    "/usr/bin/xcrun simctl install " + UDID + " /run/DerivedData/Build/Products/Debug-iphonesimulator/Weather.app",
                    "/usr/bin/xcrun simctl launch " + UDID + " app.weather",
                    "/candidate/axe describe-ui --agent --udid " + UDID]
        calls = []
        for index, command in enumerate(commands, 1):
            call = Call(index, str(index), "Bash", command, {}, index, result_line=index + 1,
                        text="app.weather: 42" if index == 3 else "** BUILD SUCCEEDED **" if index == 1 else "(Bash completed with no output)", process_completed=True)
            classify(call, "axe", [])
            calls.append(call)
        return calls, expected

    def test_supplied_weather_setup_passes(self):
        calls, expected = self.setup_calls()
        self.assertEqual(set(statuses(setup_checks(calls, "weather", expected)).values()), {"passed"})

    def test_setup_cannot_be_skipped_or_done_after_ui(self):
        calls, expected = self.setup_calls()
        self.assertEqual(statuses(setup_checks(calls[1:], "weather", expected))["setup.build"], "failed")
        calls[0].number = 5
        self.assertEqual(statuses(setup_checks(calls, "weather", expected))["setup.contract"], "failed")

    def test_build_requires_completed_process_or_terminal_proof(self):
        calls, expected = self.setup_calls()
        calls[0].text = "<persisted-output>preview only</persisted-output>"
        self.assertEqual(statuses(setup_checks(calls, "weather", expected))["setup.build"], "passed")
        calls[0].process_completed = None
        self.assertEqual(statuses(setup_checks(calls, "weather", expected))["setup.build"], "unverified")
        read = Call(5, "read", "Read", "", {}, 6, text="42→** BUILD SUCCEEDED **", category="publicOutput", evidence_call=1)
        self.assertEqual(statuses(setup_checks(calls + [read], "weather", expected))["setup.build"], "passed")
        read.evidence_call = 2
        self.assertEqual(statuses(setup_checks(calls + [read], "weather", expected))["setup.build"], "unverified")

    def test_async_or_interrupted_receipt_is_not_completed_process(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "claude.jsonl"
            data = events("Bash", {"command": "/candidate/axe describe-ui --agent --udid " + UDID}, "output", 1)
            data[1]["message"]["content"][0]["is_error"] = False
            for receipt, wanted in (({"interrupted": False}, True), ({"interrupted": True}, False), ({"interrupted": False, "backgroundTaskId": "running"}, False)):
                data[1]["tool_use_result"] = receipt
                file.write_text("\n".join(json.dumps(event) for event in data))
                calls, _ = read_transcript(file, "axe", directory)
                self.assertIs(calls[0].process_completed, wanted)

    def test_background_execution_requires_review(self):
        call = Call(1, "id", "Bash", "/candidate/axe describe-ui --agent --udid " + UDID, {"run_in_background": True}, 1)
        classify(call, "axe", [])
        self.assertEqual(call.category, "unknown")

    def test_only_rocket_screenshot_png_redirect_inside_run_is_allowed(self):
        for target, wanted in (("/run/image.png", "ui"), ("/outside/image.png", "unknown"), ("/run/source.swift", "unknown")):
            call = Call(1, "id", "Bash", "/candidate/rocketsim screenshot --udid " + UDID + " > " + target, {}, 1)
            classify(call, "rocketsim", [], run_directory="/run")
            self.assertEqual(call.category, wanted)

    def test_wrong_project_reused_build_directory_or_parallel_build_fails(self):
        for before, after in (("/source/Weather.xcodeproj", "/other/Weather.xcodeproj"), ("/run/DerivedData", "/old/DerivedData"), ("-jobs 1", "-jobs 8")):
            calls, expected = self.setup_calls()
            calls[0].command = calls[0].command.replace(before, after)
            classify(calls[0], "axe", [])
            self.assertEqual(statuses(setup_checks(calls, "weather", expected))["setup.contract"], "failed")

    def test_launch_requires_matching_bundle_and_positive_pid(self):
        calls, expected = self.setup_calls()
        calls[2].text = "different.app: 42"
        self.assertEqual(statuses(setup_checks(calls, "weather", expected))["setup.launch"], "failed")
        calls[2].text = "app.weather: 42"
        self.assertEqual(statuses(setup_checks(calls[2:], "contacts", expected))["setup.launch"], "passed")

    def test_rocket_do_and_wait_are_readable_without_extra_calls(self):
        call = Call(1, "id", "Bash", "/candidate/rocketsim do --udid " + UDID + " --step 'interact tap --id 1' --step 'wait keyboard --state shown'", {}, 1,
                    text=json.dumps({"rs": "1", "ok": True, "data": {"steps": [{"kind": "interact", "result": {}}, {"kind": "wait", "result": {}}]}}))
        classify(call, "rocketsim", [Node("1", "button", "Add")])
        self.assertEqual(call.category, "ui")
        self.assertEqual([(action.kind, action.label) for action in call.actions], [("tap", "Add"), ("observe", "")])
        self.assertEqual(statuses(identity_checks([call], "/candidate/rocketsim", UDID))["identity.simulator"], "passed")

    def test_rocket_batch_other_device_is_detected(self):
        call = Call(1, "id", "Bash", "/candidate/rocketsim do --udid " + UDID + " --step 'interact tap --id 1 --udid wrong'", {}, 1, text='{"rs":"1","ok":true,"data":{"steps":[{"kind":"interact","result":{}}]}}')
        classify(call, "rocketsim", [])
        self.assertEqual(statuses(identity_checks([call], "/candidate/rocketsim", UDID))["identity.simulator"], "failed")

    def test_batch_file_uses_only_earlier_recorded_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            batch = str(root / "batch.json")
            write = events("Write", {"file_path": batch, "content": '{"steps":[{"action":"type","id":"field","text":"London"}]}'}, "created", 1)
            use = events("Bash", {"command": "/candidate/axe batch --agent --file " + batch + " --udid " + UDID}, '{"schema":"axe.output.agent-result","didError":false,"data":{"batch":{"completedSteps":1}}}', 2)
            file = root / "claude.jsonl"
            file.write_text("\n".join(json.dumps(event) for event in write + use))
            calls, errors = read_transcript(file, "axe", root)
            self.assertFalse(errors)
            self.assertEqual(calls[0].category, "batchPayload")
            self.assertEqual(calls[1].actions[0].value, "London")
            file.write_text("\n".join(json.dumps(event) for event in use + write))
            calls, _ = read_transcript(file, "axe", root)
            self.assertNotEqual(calls[0].actions[0].kind, "type")
            self.assertEqual(calls[1].category, "unknown")

    def test_unrelated_write_and_read_remain_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "claude.jsonl"
            data = events("Write", {"file_path": "/source/app.json", "content": "{}"}, "created", 1)
            data += events("Read", {"file_path": "/source/app.swift"}, "source code", 2)
            file.write_text("\n".join(json.dumps(event) for event in data))
            calls, _ = read_transcript(file, "axe", directory)
            self.assertEqual([call.category for call in calls], ["unknown", "unknown"])

    def test_reads_of_the_installed_skill_count_as_help(self):
        with tempfile.TemporaryDirectory() as directory:
            cwd = Path(directory).resolve() / "cwd"
            file = Path(directory) / "claude.jsonl"
            data = events("Read", {"file_path": str(cwd / ".claude/skills/axe/references/batch-reference.md")}, "# batch", 1)
            data += events("Read", {"file_path": str(cwd / "notes.md")}, "notes", 2)
            data += events("Read", {"file_path": "/Users/someone/.claude/skills/other/SKILL.md"}, "other", 3)
            for event in data:
                event["cwd"] = str(cwd)
            file.write_text("\n".join(json.dumps(event) for event in data))
            calls, _ = read_transcript(file, "axe", directory)
            self.assertEqual([call.category for call in calls], ["help", "unknown", "unknown"])

    def test_public_overflow_read_preserves_exact_cost_and_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "claude.jsonl"
            output = json.dumps({"schema": "axe.output.agent-result", "data": {"capture": {"rows": ["e1|tap|button|Add|"]}}})
            data = events("Bash", {"command": "/candidate/axe describe-ui --agent --udid " + UDID}, "<persisted-output>\nFull output saved to: /public/overflow.txt\n</persisted-output>", 1)
            data += events("Read", {"file_path": "/public/overflow.txt"}, "     1→" + output, 2)
            file.write_text("\n".join(json.dumps(event) for event in data))
            calls, _ = read_transcript(file, "axe", directory)
            self.assertEqual(calls[1].category, "publicOutput")
            self.assertTrue(calls[1].text.startswith("     1→"))
            self.assertEqual(calls[1].captures[0].call, 1)
            self.assertEqual(calls[1].captures[0].nodes[0].label, "Add")


if __name__ == "__main__":
    unittest.main()
