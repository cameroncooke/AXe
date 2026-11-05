"""Offline checks for the stable command entry point; no simulator or model jobs."""
import contextlib
import io
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import cli


class CommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        patcher = patch.object(cli, 'HERE', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        python = self.root / '.venv/bin/python3'
        python.parent.mkdir(parents=True)
        python.touch()
        (self.root / 'config.local.json').write_text('{}')

    def test_no_command_runs_with_local_defaults(self):
        with patch.object(cli, 'run_engine', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(cli.main([]), 0)
        command = run.call_args.args[0]
        self.assertEqual(command[:3], [str(self.root / '.venv/bin/python3'),
                                      str(self.root / 'benchmark.py'), 'run'])
        self.assertEqual(Path(command[command.index('--config') + 1]).parent.parent, self.root / 'artifacts')
        self.assertEqual(command[command.index('--registry') + 1], str(self.root / 'baselines.json'))
        self.assertEqual(Path(command[command.index('--output') + 1]).parent, self.root / 'artifacts')
        self.assertNotIn('shell', run.call_args.kwargs)

    def test_flags_without_subcommand_preserve_selected_scope(self):
        with patch.object(cli, 'run_engine', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(cli.main(['--tools', 'axe', '--scenarios', 'weather']), 0)
        command = run.call_args.args[0]
        self.assertEqual(command[command.index('--tools'):command.index('--tools') + 4],
                         ['--tools', 'axe', '--scenarios', 'weather'])

    def test_missing_config_never_starts_job(self):
        (self.root / 'config.local.json').unlink()
        with patch.object(cli.subprocess, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main([]), 2)
        run.assert_not_called()

    def test_failed_run_is_imported_and_still_fails(self):
        output = self.root / 'evidence'
        output.mkdir()
        (output / 'summary.json').write_text('{}')
        with patch.object(cli, 'run_engine', return_value=subprocess.CompletedProcess([], 1)), \
                patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(cli.main(['run', '--output', str(output)]), 1)
        self.assertEqual(run.call_args.args[0][1:4],
                         [str(self.root / 'history.py'), 'import', str(output)])
        self.assertIs(run.call_args.kwargs['stdout'], cli.sys.stderr)

    def test_compare_does_not_run_benchmark_or_modify_baseline(self):
        report = self.root / 'report with spaces.json'
        with patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(cli.main(['compare', str(report)]), 0)
        self.assertEqual(run.call_args.args[0][2:4], ['compare', str(report)])
        self.assertEqual(run.call_count, 1)

    def test_history_rejects_missing_import_source(self):
        with patch.object(cli.subprocess, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(['history', 'import']), 2)
        run.assert_not_called()

    def test_test_command_only_discovers_offline_tests(self):
        with patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.assertEqual(cli.main(['test']), 0)
        self.assertEqual(run.call_args.args[0][1:],
                         ['-m', 'unittest', 'discover', '-s', str(self.root), '-p', 'test_*.py'])

    def test_environment_removes_external_python_paths(self):
        with patch.dict(os.environ, {'PYTHONPATH': '/other', 'PYTHONHOME': '/other'}):
            env = cli.local_environment()
        self.assertNotIn('PYTHONPATH', env)
        self.assertNotIn('PYTHONHOME', env)
        self.assertEqual(env['TIKTOKEN_CACHE_DIR'], str(self.root / '.cache/tiktoken'))

    def test_default_artifact_directories_are_unique(self):
        first, second = cli.artifact_directory(), cli.artifact_directory()
        self.assertNotEqual(first, second)
        self.assertEqual(first.parent, self.root / 'artifacts')

    def test_bundled_defaults_preserve_original_config_and_explicit_paths(self):
        source = self.root / 'config.local.json'
        source.write_text('{"simulator":"explicit","tools":{"axe":{"executable":"/explicit/axe"}}}')
        original = source.read_bytes()
        value = cli.resolved_config(source)
        self.assertEqual(value['xcodebuildmcp'], str(self.root / 'vendor/xcodebuildmcp'))
        self.assertEqual(value['weatherProject'], str(self.root / 'apps/Weather/Weather.xcodeproj'))
        self.assertEqual(value['simulator'], 'explicit')
        self.assertEqual(value['tools']['axe']['executable'], '/explicit/axe')
        self.assertEqual(source.read_bytes(), original)
        source.write_text(json.dumps({'xcodebuildmcp': '/custom/harness', 'weatherProject': '/custom/app'}))
        self.assertEqual(cli.resolved_config(source)['xcodebuildmcp'], '/custom/harness')

    def test_setup_installs_only_local_dependencies_and_preserves_config(self):
        vendor = self.root / 'vendor/xcodebuildmcp'
        vendor.mkdir(parents=True)
        (vendor / 'package-lock.json').write_text('{}')
        config = self.root / 'config.local.json'
        original = config.read_bytes()
        with patch.object(cli.shutil, 'which', return_value='/fixture/npm'), \
                patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(['setup', '--python', '/usr/bin/python3']), 0)
        calls = run.call_args_list
        self.assertIn('--require-virtualenv', calls[0].args[0])
        self.assertEqual(calls[0].args[0][0], str(self.root / '.venv/bin/python3'))
        self.assertEqual(calls[2].args[0], ['/fixture/npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund'])
        self.assertEqual(calls[2].kwargs['cwd'], str(vendor))
        self.assertEqual(config.read_bytes(), original)

    def test_interrupt_waits_for_owned_engine_then_imports_history(self):
        output = self.root / 'evidence'
        output.mkdir()
        (output / 'summary.json').write_text('{}')
        child = Mock(pid=4321)
        child.poll.return_value = None
        child.wait.side_effect = [KeyboardInterrupt(), 130]
        with patch.object(cli.subprocess, 'Popen', return_value=child) as popen, \
                patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as archive, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(['--output', str(output)]), 130)
        child.send_signal.assert_called_once_with(signal.SIGINT)
        self.assertEqual(child.wait.call_count, 2)
        self.assertTrue(popen.call_args.kwargs['start_new_session'])
        archive.assert_called_once()
        self.assertFalse(list((self.root / 'artifacts').glob('.benchmark-config-*')))

    def test_sigterm_is_forwarded_to_only_the_owned_engine(self):
        child = Mock(pid=4322)
        child.poll.return_value = None
        handlers = {}
        def wait(timeout):
            handlers[signal.SIGTERM](signal.SIGTERM, None)
            return 130
        child.wait.side_effect = wait
        with patch.object(cli.subprocess, 'Popen', return_value=child), \
                patch.object(cli.signal, 'signal', side_effect=lambda sig, handler: handlers.update({sig: handler})), \
                contextlib.redirect_stderr(io.StringIO()):
            result = cli.run_engine(['engine'], {})
        self.assertEqual(result.returncode, 143)
        child.send_signal.assert_called_once_with(signal.SIGTERM)
        child.kill.assert_not_called()

    def test_cleanup_timeout_retains_config_and_does_not_import(self):
        child = Mock(pid=4323)
        child.poll.return_value = None
        child.wait.side_effect = KeyboardInterrupt()
        with patch.object(cli.subprocess, 'Popen', return_value=child), \
                patch.object(cli.time, 'monotonic', side_effect=[0, 61]), \
                patch.object(cli.subprocess, 'run') as archive, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main([]), 2)
        self.assertEqual(len(list((self.root / 'artifacts').glob('.benchmark-config-*/config.json'))), 1)
        archive.assert_not_called()
        child.kill.assert_not_called()

    def test_history_failure_does_not_report_success(self):
        output = self.root / 'evidence'
        output.mkdir()
        (output / 'summary.json').write_text('{}')
        with patch.object(cli, 'run_engine', return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2)):
            self.assertEqual(cli.main(['--output', str(output)]), 2)

    def test_accept_imports_first_and_uses_retained_report(self):
        retained = self.root / 'history/run-id/report.json'
        retained.parent.mkdir(parents=True)
        retained.write_text('{}')
        receipt = json.dumps({'imports': [{'report': str(retained)}]})
        results = [subprocess.CompletedProcess([], 0, stdout=receipt, stderr=''),
                   subprocess.CompletedProcess([], 0)]
        with patch.object(cli.subprocess, 'run', side_effect=results) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(['accept', str(self.root / 'external.json')]), 0)
        self.assertEqual(run.call_args_list[0].args[0][1:3], [str(self.root / 'history.py'), 'import'])
        self.assertEqual(run.call_args_list[1].args[0][2:4], ['accept', str(retained)])

    def test_failed_import_does_not_attempt_acceptance(self):
        with patch.object(cli.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 2, stdout='', stderr='rejected')) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(['accept', str(self.root / 'external.json')]), 2)
        self.assertEqual(run.call_count, 1)


if __name__ == '__main__':
    unittest.main()
