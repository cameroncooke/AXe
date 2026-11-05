"""Owned-process tests; optional live proof uses only short-lived Python helpers."""
from dataclasses import replace
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from processes import ProcessRecord, ProcessTracker


def row(pid, ppid, name='python', started='Thu Nov 5 12:00:00 2026'):
    return ProcessRecord(pid, ppid, pid, started, 'S', name)


class ProcessTests(unittest.TestCase):
    def test_detached_descendants_remain_owned_after_reparenting(self):
        rows = {41000: row(41000, 40000), 41001: row(41001, 41000),
                41002: row(41002, 41001), 42000: row(42000, 1)}
        def stop(pid, sig):
            rows.pop(pid, None)
        with patch('processes.process_snapshot', side_effect=lambda: dict(rows)), \
                patch('processes.os.kill', side_effect=stop) as kill:
            tracker = ProcessTracker(41000)
            tracker.sample()
            rows.pop(41000)
            rows[41001] = replace(rows[41001], ppid=1)
            receipt = tracker.cleanup()
        self.assertTrue(receipt['complete'])
        self.assertEqual({call.args[0] for call in kill.call_args_list}, {41001, 41002})
        self.assertEqual(kill.call_args_list[0].args[0], 41002)
        self.assertIn(42000, rows)

    def test_reused_pid_is_not_signalled(self):
        rows = {41000: row(41000, 40000), 41001: row(41001, 41000)}
        with patch('processes.process_snapshot', side_effect=lambda: dict(rows)), patch('processes.os.kill') as kill:
            tracker = ProcessTracker(41000)
            tracker.sample()
            rows.pop(41000)
            rows[41001] = row(41001, 1, started='Thu Nov 5 12:00:01 2026')
            self.assertTrue(tracker.cleanup()['complete'])
        kill.assert_not_called()

    def test_unique_suite_marker_adopts_only_its_detached_model(self):
        root = '/tmp/axe-bench-weather-axe-0123456789ab'
        rows = {41000: row(41000, 40000), 41001: row(41001, 1, 'claude'),
                41002: row(41002, 41001), 42000: row(42000, 1, 'claude')}
        output = (f'41001 claude --mcp-config {root}/timestamp/mcp-config.json\n'
                  '42000 claude --mcp-config /tmp/other/mcp-config.json\n')
        with patch('processes.process_snapshot', return_value=rows), \
                patch('processes.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout=output)):
            tracker = ProcessTracker(41000, root)
            tracker.sample()
        self.assertEqual(set(tracker.owned), {41000, 41001, 41002})

    def test_missing_snapshot_refuses_clean_result(self):
        with patch('processes.process_snapshot', side_effect=[{41000: row(41000, 40000)}, subprocess.TimeoutExpired('ps', 2)]), \
                patch('processes.os.kill') as kill:
            receipt = ProcessTracker(41000).cleanup()
        self.assertFalse(receipt['complete'])
        self.assertIn('TimeoutExpired', receipt['errors'][0])
        kill.assert_not_called()

    def test_constructor_survives_first_snapshot_failure_and_can_retry(self):
        with patch('processes.process_snapshot', side_effect=[subprocess.TimeoutExpired('ps', 2),
                                                              {41000: row(41000, 40000)}]) as snapshot:
            tracker = ProcessTracker(41000)
            snapshot.assert_not_called()
            with self.assertRaises(subprocess.TimeoutExpired):
                tracker.sample()
            self.assertFalse(tracker.initialized)
            self.assertIn(41000, tracker.sample())

    def test_missing_launcher_can_adopt_only_exact_model_scope(self):
        root = '/tmp/axe-bench-weather-axe-0123456789ab'
        rows = {41001: row(41001, 1, 'claude'), 41002: row(41002, 41001)}
        output = f'41001 claude --mcp-config {root}/timestamp/mcp-config.json\n'
        with patch('processes.process_snapshot', return_value=rows), \
                patch('processes.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout=output)):
            self.assertEqual(set(ProcessTracker(41000, root).sample()), {41001, 41002})
            with self.assertRaisesRegex(RuntimeError, 'exited before'):
                ProcessTracker(41000).sample()

    def test_normal_completion_detects_and_stops_retained_orphan(self):
        rows = {41000: row(41000, 40000), 41001: row(41001, 41000)}
        def stop(pid, sig):
            rows.pop(pid, None)
        with patch('processes.process_snapshot', side_effect=lambda: dict(rows)), patch('processes.os.kill', side_effect=stop):
            tracker = ProcessTracker(41000)
            tracker.sample()
            rows.pop(41000)
            rows[41001] = replace(rows[41001], ppid=1)
            receipt = tracker.cleanup()
        self.assertEqual([item['pid'] for item in receipt['initiallyRunning']], [41001])
        self.assertTrue(receipt['complete'])

    def test_term_timeout_escalates_only_owned_identity(self):
        rows = {41000: row(41000, 40000), 42000: row(42000, 1)}
        def stop(pid, sig):
            if sig == signal.SIGKILL:
                rows.pop(pid, None)
        with patch('processes.process_snapshot', side_effect=lambda: dict(rows)), \
                patch('processes.os.kill', side_effect=stop) as kill:
            receipt = ProcessTracker(41000).cleanup(term_seconds=.01, kill_seconds=.01)
        self.assertTrue(receipt['complete'])
        self.assertEqual([call.args for call in kill.call_args_list],
                         [(41000, signal.SIGTERM), (41000, signal.SIGKILL)])
        self.assertIn(42000, rows)

    def test_surviving_owned_process_refuses_complete_cleanup(self):
        rows = {41000: row(41000, 40000)}
        with patch('processes.process_snapshot', return_value=rows), patch('processes.os.kill'):
            receipt = ProcessTracker(41000).cleanup(term_seconds=.01, kill_seconds=.01)
        self.assertFalse(receipt['complete'])
        self.assertEqual([item['pid'] for item in receipt['remaining']], [41000])

    @unittest.skipUnless(os.environ.get('AXE_PROCESS_HELPER_TEST') == '1', 'Opt-in local Python process proof')
    def test_live_nested_detached_helpers_and_unrelated_sentinel(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'pids.json'
            leaf = 'import time; time.sleep(20)'
            middle = ('import os,subprocess,sys,time,json; '
                      f'p=subprocess.Popen([sys.executable,"-c",{leaf!r}],start_new_session=True); '
                      f'open({str(marker)!r},"w").write(json.dumps([os.getpid(),p.pid])); '
                      'time.sleep(20)')
            top = ('import subprocess,sys,time; '
                   f'p=subprocess.Popen([sys.executable,"-c",{middle!r}],start_new_session=True); '
                   'time.sleep(20)')
            sentinel = subprocess.Popen([sys.executable, '-c', leaf], start_new_session=True)
            parent = subprocess.Popen([sys.executable, '-c', top], start_new_session=True)
            tracker = None
            try:
                tracker = ProcessTracker(parent.pid)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    active = tracker.sample()
                    if marker.exists():
                        descendants = json.loads(marker.read_text())
                        if all(pid in active for pid in descendants):
                            break
                    time.sleep(.05)
                else:
                    self.fail('Nested helper descendants were not observed')
                self.assertEqual(len({active[pid].pgid for pid in [parent.pid, *descendants]}), 3)
                parent.terminate()
                parent.wait(timeout=2)
                receipt = tracker.cleanup()
                self.assertTrue(receipt['complete'], receipt)
                self.assertTrue(set(descendants).issubset({item['pid'] for item in receipt['signals']}))
                self.assertIsNone(sentinel.poll(), 'Unrelated helper was stopped')
            finally:
                if tracker:
                    tracker.cleanup(term_seconds=.5, kill_seconds=.5)
                if parent.poll() is None:
                    parent.kill()
                parent.wait(timeout=2)
                sentinel.terminate()
                sentinel.wait(timeout=2)


if __name__ == '__main__':
    unittest.main()
