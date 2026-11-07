"""Offline runner checks. Every live or model boundary is mocked."""
from contextlib import ExitStack, nullcontext
from copy import deepcopy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import benchmark
from baselines import comparison_key, validate_result


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / 'axe-bench-weather-axe-test'
        self.config = {
            'xcodebuildmcp': str(self.root / 'xbm'), 'developerDir': '/Xcode/Developer',
            'simulator': '00000000-0000-0000-0000-000000000001',
            'setupAxe': '/candidate/axe', 'preparationProfiles': {},
            'model': 'claude-opus-4-7', 'maxClaudeSeconds': 900,
        }
        self.host = {
            'claudeVersion': '2.1.281', 'deviceType': 'iPhone 18 Pro',
            'runtimeVersion': '27.3 (A123)',
            'screenWidth': 402, 'screenHeight': 874, 'rotation': 0,
            'hostOS': '27.0', 'hostBuild': 'A456', 'hostArchitecture': 'arm64',
            'hostModel': 'Mac', 'xcodeVersion': '27.3 A123', 'nodeVersion': '24.0',
        }
        self.hashes = {field: 'a' * 64 for field in (
            'harnessSHA256', 'scorerSHA256', 'guideSetSHA256', 'sharedRulesSHA256', 'runnerSHA256')}
        self.tool = {'name': 'axe', 'version': '1.0', 'binarySHA256': 'b' * 64,
                     'executable': '/candidate/axe', 'companionApp': None}
        self.app = {'bundleId': 'test.Weather', 'sourceSHA256': 'c' * 64}
        self.score = {
            'status': 'passed', 'correctness': {'status': 'passed', 'checks': [
                {'id': 'task.fact', 'status': 'passed'}]},
            'metrics': {'totalCalls': 17, 'elapsedSeconds': 182.0,
                        'returnedTextTokens': 6805, 'imageCount': 0, 'imageBytes': 0,
                        'tokenStatus': 'measured', 'tokenizerVersion': '0.12.0'},
            'warnings': [], 'transcriptSHA256': 'd' * 64,
            'observedRuntime': {'model': 'claude-opus-4-7', 'claudeVersion': '2.1.281',
                                'initializationCount': 1},
        }
        xbm = Path(self.config['xcodebuildmcp'])
        tsx = xbm / 'node_modules/.bin/tsx'
        tsx.parent.mkdir(parents=True)
        tsx.write_text('offline fixture')
        native = xbm / 'out.nosync/claude-benchmarks' / self.output.name / 'run'
        native.mkdir(parents=True)
        (native / 'claude.jsonl').write_text('{}\n')
        self.evidence = self.root / 'evidence'
        self.evidence.mkdir()
        (self.evidence / 'result.json').write_text(json.dumps({
            'run': {'claude': {'observedModel': 'claude-opus-4-7'}}}))
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch('sys.stderr', io.StringIO()))
        self.mocks = {}
        values = {
            'tool_info': deepcopy(self.tool), 'host_environment': deepcopy(self.host),
            'app_identity': deepcopy(self.app), 'inputs': deepcopy(self.hashes),
            'resource_sample': {'processes': []}, 'lifecycle': None,
            'prepare': {'status': 'ready'}, 'archive_run': self.evidence,
            'score_run': deepcopy(self.score), 'digest': 'e' * 64, 'tree_digest': 'f' * 64,
            'run_monitored': {'exitCode': 0, 'stopReason': None},
        }
        for name, value in values.items():
            self.mocks[name] = self.stack.enter_context(patch.object(benchmark, name, return_value=value))

        def suite(config, scenario, name, identity, app, output):
            skill = output / 'skills' / benchmark.skill_name(name)
            skill.mkdir(parents=True)
            (skill / 'SKILL.md').write_text('generic guide')
            return {'name': output.name}

        self.mocks['make_suite'] = self.stack.enter_context(patch.object(benchmark, 'make_suite', side_effect=suite))

    def run_case(self):
        return benchmark.run_case(self.config, 'weather', 'axe', self.output, {})

    def report(self):
        return json.loads((self.output / 'report.json').read_text())

    def test_success_saves_verified_result_and_exact_measured_metrics(self):
        result = self.run_case()
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['metrics'], self.score['metrics'])
        self.assertEqual(self.report(), result)
        validate_result(result)
        self.assertEqual(self.mocks['run_monitored'].call_count, 1)
        self.assertEqual(self.mocks['lifecycle'].call_count, 2)
        self.assertFalse(any(call.kwargs.get('launch') for call in self.mocks['lifecycle'].call_args_list))

    def test_preparation_receives_launched_pid(self):
        self.mocks['lifecycle'].return_value = 12345
        result = benchmark.run_case(self.config, 'contacts', 'axe', self.output, {})
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(self.mocks['prepare'].call_args.kwargs['expected_pid'], 12345)

    def test_candidate_versions_do_not_change_comparison_key(self):
        first = self.run_case()
        second = deepcopy(first)
        second['tool'].update(version='2.0', binarySHA256='f' * 64,
                              executable='/different/candidate/axe', guideSHA256='0' * 64)
        self.assertEqual(comparison_key(first), comparison_key(second))

    def test_runtime_build_changes_comparison_key(self):
        first = self.run_case()
        second = deepcopy(first)
        host = {**self.host, 'runtimeVersion': '27.3 (A124)'}
        second['contract'] = {**benchmark.contract(self.config, 'weather', host, self.app, self.hashes),
                              'modelVersion': self.config['model'], 'tokenizerVersion': '0.12.0'}
        self.assertNotEqual(comparison_key(first), comparison_key(second))

    def test_changed_preparation_inventory_changes_key_but_tool_version_does_not(self):
        first = self.run_case()
        first['scenario'] = 'contacts'
        config = {**self.config, 'preparationProfiles': {'contacts': {'baselineRows': ['Existing Contact']}}}
        first['contract'] = {**benchmark.contract(config, 'contacts', self.host, self.app, self.hashes),
                             'modelVersion': self.config['model'], 'tokenizerVersion': '0.12.0'}
        second = deepcopy(first)
        second['tool'].update(version='2.0', binarySHA256='f' * 64)
        self.assertEqual(comparison_key(first), comparison_key(second))
        config['preparationProfiles']['contacts']['baselineRows'].append('Another Contact')
        second['contract'] = {**benchmark.contract(config, 'contacts', self.host, self.app, self.hashes),
                              'modelVersion': self.config['model'], 'tokenizerVersion': '0.12.0'}
        self.assertNotEqual(comparison_key(first), comparison_key(second))

    def test_changed_binary_cannot_pass_or_replace_baseline(self):
        self.mocks['tool_info'].side_effect = [deepcopy(self.tool), {**self.tool, 'binarySHA256': 'f' * 64}]
        result = self.run_case()
        self.assertEqual(result['status'], 'unverified')
        check = next(row for row in result['correctness']['checks'] if row['id'] == 'inputs.unchanged')
        self.assertEqual(check['status'], 'unverified')

    def test_changed_runtime_library_cannot_pass_with_same_cli_binary(self):
        before = {**self.tool, 'runtimeFiles': {'framework': 'old-hash'}}
        after = {**self.tool, 'runtimeFiles': {'framework': 'new-hash'}}
        self.mocks['tool_info'].side_effect = [before, after]
        self.assertEqual(self.run_case()['status'], 'unverified')

    def test_different_observed_model_is_not_an_eligible_success(self):
        self.mocks['score_run'].return_value['observedRuntime']['model'] = 'another-model'
        result = self.run_case()
        self.assertEqual(result['status'], 'unverified')
        self.assertEqual(result['contract']['modelVersion'], 'another-model')

    def test_monitor_stop_cannot_be_overridden_by_task_facts(self):
        self.mocks['run_monitored'].return_value = {'exitCode': -15, 'stopReason': 'Memory guard'}
        result = self.run_case()
        self.assertEqual(result['status'], 'unverified')
        check = next(row for row in result['correctness']['checks'] if row['id'] == 'runner.completed')
        self.assertEqual(check['status'], 'unverified')

    def test_failed_preparation_saves_report_without_running_model(self):
        self.mocks['prepare'].return_value = {'status': 'blocked', 'reason': 'record mismatch'}
        result = self.run_case()
        self.assertEqual(result['status'], 'blocked')
        self.assertIn('record mismatch', result['reason'])
        self.assertEqual(self.report(), result)
        self.mocks['run_monitored'].assert_not_called()

    def test_missing_native_transcript_is_unverified_and_reported(self):
        self.mocks['make_suite'].side_effect = None
        self.mocks['make_suite'].return_value = {'name': 'not-present'}
        result = self.run_case()
        self.assertEqual(result['status'], 'unverified')
        self.assertIn('transcript', result['reason'])
        self.assertEqual(self.report(), result)

    def test_interrupt_saves_reason_and_propagates_to_stop_matrix(self):
        self.mocks['run_monitored'].return_value = {'exitCode': -15, 'stopReason': 'KeyboardInterrupt: '}
        with self.assertRaises(KeyboardInterrupt):
            self.run_case()
        result = self.report()
        self.assertEqual(result['status'], 'unverified')
        self.assertIn('interrupted', result['reason'].lower())
        self.mocks['score_run'].assert_not_called()

    def test_matrix_records_interrupted_case_and_does_not_start_next_tool(self):
        matrix_output = self.root / 'matrix'
        def interrupted(config, scenario, tool, output, env):
            output.mkdir()
            report = {'schema': 'axe.agent-benchmark.result', 'schemaVersion': 1,
                      'runId': output.name, 'scenario': scenario, 'tool': {'name': tool},
                      'status': 'unverified', 'contract': {}, 'metrics': {},
                      'correctness': {'status': 'unverified', 'checks': []},
                      'reason': 'KeyboardInterrupt'}
            benchmark.save(output / 'report.json', report)
            raise KeyboardInterrupt()
        with patch.object(benchmark, 'load_config', return_value=self.config), \
                patch.object(benchmark, 'simulator_lock', return_value=nullcontext()), \
                patch.object(benchmark, 'run_case', side_effect=interrupted) as run, \
                patch.object(benchmark.sys, 'argv', ['benchmark.py', 'run', '--config', 'config',
                    '--tools', 'axe', 'flowdeck', '--scenarios', 'weather', '--output', str(matrix_output)]):
            with self.assertRaises(KeyboardInterrupt):
                benchmark.main()
        self.assertEqual(run.call_count, 1)
        summary = json.loads((matrix_output / 'summary.json').read_text())
        self.assertEqual(len(summary['runs']), 1)
        self.assertEqual(summary['runs'][0]['tool']['name'], 'axe')
        self.assertEqual(summary['runs'][0]['status'], 'unverified')

    def test_incomplete_cleanup_stops_matrix_before_next_tool(self):
        matrix_output = self.root / 'matrix-cleanup'
        case = {'status': 'unverified', 'tool': {'name': 'axe'},
                'execution': {'cleanup': {'complete': False, 'remaining': [{'pid': 43211}]}}}
        with patch.object(benchmark, 'load_config', return_value=self.config), \
                patch.object(benchmark, 'simulator_lock', return_value=nullcontext()), \
                patch.object(benchmark, 'run_case', return_value=case) as run, \
                patch.object(benchmark.sys, 'argv', ['benchmark.py', 'run', '--config', 'config',
                    '--tools', 'axe', 'flowdeck', '--scenarios', 'weather', '--output', str(matrix_output)]):
            with self.assertRaisesRegex(RuntimeError, 'cleanup is incomplete'):
                benchmark.main()
        run.assert_called_once()
        summary = json.loads((matrix_output / 'summary.json').read_text())
        self.assertEqual(len(summary['runs']), 1)
        self.assertFalse(summary['runs'][0]['execution']['cleanup']['complete'])


class LifecycleTests(unittest.TestCase):
    def test_rocket_requires_running_app_and_reachable_connection(self):
        for running, reachable, expected in [(True, True, 'ready'),
                                             (True, False, 'blocked'), (False, False, 'blocked')]:
            with self.subTest(running=running, reachable=reachable), patch('benchmark.subprocess.run',
                    return_value=SimpleNamespace(returncode=0, stdout=json.dumps({'ok': True,
                        'data': {'rocket_sim_running': running, 'ipc_reachable': reachable}}))):
                result = benchmark.service_ready({'name': 'rocketsim', 'executable': '/rocketsim'}, {})
                self.assertEqual(result['status'], expected)

    def test_launch_requires_exact_bundle_and_positive_pid(self):
        with tempfile.TemporaryDirectory() as folder:
            receipt = Path(folder) / 'launch.json'
            for text, expected in [('com.example.App: 12345\n', 12345),
                                   ('com.other.App: 12345\n', None),
                                   ('com.example.App: 0\n', None), ('', None)]:
                with self.subTest(text=text), patch('benchmark.subprocess.run', return_value=
                        SimpleNamespace(returncode=0, stdout=text, stderr='')):
                    if expected is None:
                        with self.assertRaisesRegex(RuntimeError, 'application PID'):
                            benchmark.lifecycle({'simulator': 'device'}, {'bundleId': 'com.example.App'},
                                                {}, receipt, launch=True)
                    else:
                        self.assertEqual(benchmark.lifecycle({'simulator': 'device'},
                            {'bundleId': 'com.example.App'}, {}, receipt, launch=True), expected)


if __name__ == '__main__':
    unittest.main()
