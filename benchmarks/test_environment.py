"""Offline checks for read-only preflight and owned-process monitoring."""
from copy import deepcopy
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import environment
import monitor


UDID = "419D3218-79E5-46DE-80C0-E58126A88252"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
PANEL = {"displayId": 1, "nativeSize": [1206, 2622], "pointScale": 3,
         "currentOrientation": "rot0", "primary": True,
         "backlightState": "activeOn", "type": {"integrated": {}}}


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.state = "Booted"
        self.panels = [deepcopy(PANEL)]

    def command(self, argv, env=None, timeout=30):
        self.calls.append([str(part) for part in argv])
        if argv[1:4] == ["simctl", "list", "devices"]:
            return json.dumps({"devices": {RUNTIME: [{"udid": UDID, "name": "Audit iPhone",
                "state": self.state, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}]}})
        if argv[1:4] == ["simctl", "list", "runtimes"]:
            return json.dumps({"runtimes": [{"identifier": RUNTIME, "version": "27.2", "buildversion": "test-build"}]})
        if argv[1:5] == ["devicectl", "device", "info", "displays"]:
            Path(argv[-1]).write_text(json.dumps({"result": {"displays": self.panels}}))
            return ""
        return "recorded-version"

    def inspect(self, locked=False):
        with patch.object(environment, "command", side_effect=self.command), patch.object(environment, "lock_state", return_value=locked):
            return environment.host_environment(UDID, "/Applications/Xcode.app/Contents/Developer", {})

    def test_warm_device_metadata_uses_read_only_commands(self):
        result = self.inspect()
        self.assertEqual((result["screenWidth"], result["screenHeight"]), (402, 874))
        self.assertEqual(result["runtimeVersion"], "27.2 (test-build)")
        self.assertEqual(result["hostModel"], "recorded-version")
        forbidden = {"boot", "bootstatus", "create", "delete", "erase", "launch", "terminate", "install"}
        self.assertFalse(any(part in forbidden for argv in self.calls for part in argv))

    def test_cold_device_is_rejected_without_boot_attempt(self):
        self.state = "Shutdown"
        with self.assertRaisesRegex(RuntimeError, "existing booted"):
            self.inspect()
        self.assertEqual(len(self.calls), 1)

    def test_locked_mac_is_rejected_before_display_query(self):
        with self.assertRaisesRegex(RuntimeError, "locked"):
            self.inspect(locked=True)
        self.assertEqual(len(self.calls), 2)

    def test_landscape_geometry_is_recorded(self):
        self.panels[0]["currentOrientation"] = "rot90"
        result = self.inspect()
        self.assertEqual((result["screenWidth"], result["screenHeight"]), (874, 402))

    def test_missing_active_requires_single_lit_integrated_primary(self):
        variants = [{"active": False}, {"active": None}, {"backlightState": "off"},
                    {"type": {"external": {}}}, {"primary": False}]
        for overrides in variants:
            with self.subTest(overrides=overrides):
                self.panels = [{**deepcopy(PANEL), **overrides}]
                with self.assertRaisesRegex(RuntimeError, "active simulator display"):
                    self.inspect()
        self.panels = [deepcopy(PANEL), {**deepcopy(PANEL), "displayId": 2}]
        with self.assertRaisesRegex(RuntimeError, "active simulator display"):
            self.inspect()

    def test_exactly_one_explicit_active_display_is_required(self):
        self.panels = [{**deepcopy(PANEL), "active": False}, {**deepcopy(PANEL), "displayId": 2, "active": True}]
        self.assertEqual(self.inspect()["displayId"], 2)
        self.panels[0]["active"] = True
        with self.assertRaisesRegex(RuntimeError, "active simulator display"):
            self.inspect()

    def test_lock_flag_must_be_observed_boolean(self):
        for value in (False, True):
            reply = SimpleNamespace(stdout=plistlib.dumps({"IOConsoleLocked": value}))
            with patch.object(environment.subprocess, "run", return_value=reply):
                self.assertIs(environment.lock_state(), value)
        for data in ({}, {"IOConsoleLocked": 0}, [{"IOConsoleLocked": False}]):
            reply = SimpleNamespace(stdout=plistlib.dumps(data))
            with patch.object(environment.subprocess, "run", return_value=reply), self.assertRaises(RuntimeError):
                environment.lock_state()

    def test_source_digest_tracks_sources_but_not_build_products(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "App.swift"
            source.write_text("source one")
            before = environment.tree_digest(root)
            (root / "DerivedData").mkdir()
            (root / "DerivedData" / "output").write_text("build output")
            self.assertEqual(before, environment.tree_digest(root))
            source.write_text("source two")
            self.assertNotEqual(before, environment.tree_digest(root))

    def test_source_digest_rejects_symlink_directories_and_files(self):
        for directory_link in (False, True):
            with self.subTest(directory_link=directory_link), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source = root / "source"
                source.mkdir()
                outside = root / "outside"
                outside.mkdir()
                (outside / "target.swift").write_text("outside source")
                (source / "App.swift").write_text("normal source")
                (source / "linked").symlink_to(outside if directory_link else outside / "target.swift")
                with self.assertRaisesRegex(ValueError, "symlinks"):
                    environment.tree_digest(source)


class Process:
    pid = 43210

    def __init__(self, polls=(None, None)):
        self.polls = list(polls)
        self.returncode = None

    def poll(self):
        value = self.polls.pop(0) if self.polls else self.returncode
        if value is not None:
            self.returncode = value
        return value

    def wait(self, timeout):
        if self.returncode is None:
            self.returncode = -signal.SIGTERM
        return self.returncode


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.tracker = Mock()
        self.tracker.sample.return_value = {}
        self.tracker.cleanup.return_value = {'complete': True, 'initiallyRunning': [], 'remaining': [], 'errors': []}
        tracker_patch = patch.object(monitor, 'ProcessTracker', return_value=self.tracker)
        self.tracker_factory = tracker_patch.start()
        self.addCleanup(tracker_patch.stop)
        for target in ('time.sleep', 'signal.signal'):
            item = patch('monitor.' + target)
            item.start()
            self.addCleanup(item.stop)

    def sample(self, *, locked=False, size=1024):
        return {"elapsedAt": 0, "locked": locked, "processes": [{"pid": 999, "name": "node",
                "cpuPercent": 25.0, "rssBytes": size}], "memoryMeasure": "RSS; not physical footprint"}

    def run_fake(self, sample, *, cleanup_error=None, process=None):
        process = process or Process()
        self.tracker.cleanup.side_effect = cleanup_error
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "run"
            with patch.object(monitor.subprocess, "Popen", return_value=process) as launch, \
                    patch.object(monitor, "resource_sample", side_effect=sample if isinstance(sample, BaseException) else None,
                                 return_value=sample):
                result = monitor.run_monitored(["model", "--json"], folder, {}, output)
                saved = json.loads((output / "result.json").read_text())
                self.assertEqual(result, saved)
                self.assertTrue(launch.call_args.kwargs["start_new_session"])
                self.tracker_factory.assert_called_once_with(43210, model_run_root=None)
                return result, self.tracker.cleanup.call_args_list

    def test_lock_stop_signals_only_owned_benchmark_group(self):
        result, calls = self.run_fake(self.sample(locked=True))
        self.assertEqual(result["stopReason"], "hostLocked")
        self.assertEqual(len(calls), 1)

    def test_invalid_model_scope_cannot_spawn_a_process(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(monitor.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(ValueError, 'unique generated benchmark'):
                monitor.run_monitored(['model'], folder, {}, Path(folder) / 'run',
                                      model_run_root=Path(folder) / 'invalid-smoke-name')
        launch.assert_not_called()
        self.tracker_factory.assert_not_called()

    def test_large_unrelated_process_stops_only_benchmark(self):
        result, calls = self.run_fake(self.sample(size=21 * 1024 ** 3))
        self.assertEqual(result["stopReason"], "processMemoryLimit")
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["peakProcessRSSBytes"], 21 * 1024 ** 3)

    def test_cleanup_error_still_saves_incomplete_result(self):
        result, calls = self.run_fake(self.sample(locked=True), cleanup_error=RuntimeError('snapshot unavailable'))
        self.assertEqual(result["stopReason"], "ownedProcessCleanupIncomplete")
        self.assertFalse(result['cleanup']['complete'])
        self.assertEqual(result["exitCode"], -signal.SIGTERM)
        self.assertEqual(len(calls), 1)

    def test_keyboard_interrupt_is_recorded_for_runner_to_stop_matrix(self):
        result, calls = self.run_fake(KeyboardInterrupt())
        self.assertTrue(result["stopReason"].startswith("KeyboardInterrupt"))
        self.assertEqual(len(calls), 1)

    def test_success_does_not_signal_other_processes(self):
        result, calls = self.run_fake(self.sample(), process=Process((0, 0)))
        self.assertEqual(result["exitCode"], 0)
        self.assertIsNone(result["stopReason"])
        self.assertEqual(len(calls), 1)

    def test_normal_exit_with_remaining_owned_model_is_not_success(self):
        self.tracker.cleanup.return_value['initiallyRunning'] = [{'pid': 43211, 'name': 'claude'}]
        result, calls = self.run_fake(self.sample(), process=Process((0, 0)))
        self.assertEqual(result['stopReason'], 'ownedModelAtExit')
        self.assertEqual(len(calls), 1)

    def test_normal_exit_with_cleaned_owned_service_remains_successful(self):
        self.tracker.cleanup.return_value['initiallyRunning'] = [
            {'pid': 43211, 'name': 'axe'}, {'pid': 43212, 'name': 'SWBBuildService'},
            {'pid': 43213, 'name': 'caffeinate'}]
        result, calls = self.run_fake(self.sample(), process=Process((0, 0)))
        self.assertIsNone(result['stopReason'])
        self.assertTrue(result['cleanup']['complete'])
        self.assertEqual(len(calls), 1)

    def test_one_failed_sample_then_healthy_sample_allows_completion(self):
        process = Process((None, None, 0, 0))
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'run'
            with patch.object(monitor.subprocess, 'Popen', return_value=process), \
                    patch.object(monitor, 'resource_sample', side_effect=[
                        subprocess.TimeoutExpired('ps', 5), self.sample()]), \
                    patch.object(monitor.time, 'monotonic', side_effect=[0, 0, 5, 6]), \
                    patch.object(monitor.time, 'sleep'):
                result = monitor.run_monitored(['model'], folder, {}, output)
            samples = [json.loads(row) for row in (output / 'resources.jsonl').read_text().splitlines()]
            self.assertEqual(result['exitCode'], 0)
            self.assertIsNone(result['stopReason'])
            self.assertEqual(result['failedSamples'], 1)
            self.assertEqual(result['samples'], 2)
            self.assertIn('TimeoutExpired', samples[0]['sampleError'])
            self.assertNotIn('sampleError', samples[1])
            self.tracker.cleanup.assert_called_once_with()

    def test_three_consecutive_failed_samples_stop_only_owned_group(self):
        process = Process((None, None, None, None))
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'run'
            with patch.object(monitor.subprocess, 'Popen', return_value=process), \
                    patch.object(monitor, 'resource_sample', side_effect=subprocess.TimeoutExpired('ps', 5)), \
                    patch.object(monitor.time, 'monotonic', side_effect=[0, 0, 5, 10, 11]), \
                    patch.object(monitor.time, 'sleep'):
                result = monitor.run_monitored(['model'], folder, {}, output)
            self.assertEqual(result['stopReason'], 'resourceMonitoringUnavailable')
            self.assertEqual(result['failedSamples'], 3)
            self.assertEqual(result['samples'], 3)
            self.assertEqual(result['exitCode'], -signal.SIGTERM)
            self.tracker.cleanup.assert_called_once_with()
            self.assertEqual(result, json.loads((output / 'result.json').read_text()))

    def test_resource_sample_reports_rss_without_full_process_arguments(self):
        reply = SimpleNamespace(stdout="100 1 25.5 2048 /usr/bin/node\n101 1 5.0 4096 /Applications/Xcode.app/DeviceHub\n102 1 3.0 100 /Applications/Safari.app/Safari\n")
        with patch.object(monitor.subprocess, "run", return_value=reply), patch.object(monitor, "lock_state", return_value=False):
            sample = monitor.resource_sample()
        self.assertEqual([row["name"] for row in sample["processes"]], ["node", "DeviceHub"])
        self.assertEqual(sample["processes"][0]["rssBytes"], 2048 * 1024)
        self.assertEqual(sample["memoryMeasure"], "RSS; not physical footprint")


if __name__ == "__main__":
    unittest.main()
