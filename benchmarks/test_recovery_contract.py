"""Public command coverage and setup recovery, without app-specific exceptions."""

import unittest

from scoring import procedure_read_only, setup_checks
from transcript import Call, Node, classify


UDID = "11111111-2222-3333-4444-555555555555"


class RecoveryContractTests(unittest.TestCase):
    def launch(self, number, bundle="app.target", denied=False):
        call = Call(number, str(number), "Bash", "/usr/bin/xcrun simctl launch " + UDID + " " + bundle, {}, number,
                    result_line=number + 1, text="This command requires approval" if denied else bundle + ": 42",
                    error=denied, process_completed=None if denied else True)
        classify(call, "rocketsim", [])
        return call

    def checks(self, calls):
        expected = {"bundleId": "app.target", "developerDir": "/Xcode/Developer", "udid": UDID, "runDirectory": "/run"}
        return {row["id"]: row["status"] for row in setup_checks(calls, "contacts", expected)}

    def test_matching_relaunch_before_save_does_not_violate_setup(self):
        ui = Call(2, "ui", "Bash", "", {}, 2, category="ui")
        calls = [self.launch(1), ui, self.launch(3)]
        self.assertEqual(set(self.checks(calls).values()), {"passed"})
        self.assertEqual(procedure_read_only(calls, (4, 0), "save")["status"], "passed")

    def test_relaunch_after_save_still_violates_verification(self):
        self.assertEqual(procedure_read_only([self.launch(5)], (4, 0), "save")["status"], "failed")

    def test_denied_launch_is_not_executed_but_wrong_app_launch_fails(self):
        self.assertEqual(self.checks([self.launch(1), self.launch(3, "other.app")])["setup.contract"], "failed")
        self.assertEqual(self.checks([self.launch(1), self.launch(3, "other.app", denied=True)])["setup.contract"], "passed")
        self.assertEqual(procedure_read_only([self.launch(5, denied=True)], (4, 0), "save")["status"], "passed")

    def test_initial_launch_is_still_required(self):
        ui = Call(1, "ui", "Bash", "", {}, 1, category="ui")
        self.assertEqual(self.checks([ui, self.launch(2)])["setup.launch"], "failed")

    def test_global_status_and_time_wait_do_not_need_a_device(self):
        for command in ("status", "wait time --ms 3000", "simulator focused"):
            call = Call(1, "id", "Bash", "/candidate/rocketsim " + command, {}, 1)
            classify(call, "rocketsim", [])
            self.assertEqual(call.category, "ui")
            self.assertFalse(call.requires_device)
            self.assertFalse(call.actions)

    def test_public_native_actions_and_accessibility_audit(self):
        for command, kind in (("interact activate --id 1", "tap"), ("interact long-press --id 1", "long-press"), ("accessibility-audit", None)):
            call = Call(1, "id", "Bash", "/candidate/rocketsim " + command + " --udid " + UDID, {}, 1)
            classify(call, "rocketsim", [Node("1", "button", "Control")])
            self.assertEqual(call.category, "ui")
            self.assertTrue(call.requires_device)
            self.assertEqual([action.kind for action in call.actions], [kind] if kind else [])


if __name__ == "__main__":
    unittest.main()
