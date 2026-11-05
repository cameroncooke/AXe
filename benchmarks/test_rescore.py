"""Offline report integrity and re-scoring checks; no model or simulator jobs."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from environment import digest
from rescore import RUNNER_CHECKS, rescore
from test_baselines import result


class RescoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.evidence = self.root / 'evidence'
        self.evidence.mkdir()
        (self.evidence / 'claude.jsonl').write_text('{"fixture":"immutable transcript"}\n')
        (self.evidence / 'result.json').write_text('{"fixture":"immutable runner receipt"}\n')
        archive = {'source': '/original/runner/directory', 'sha256': {
            name: digest(self.evidence / name) for name in ('claude.jsonl', 'result.json')}}
        (self.evidence / 'archive.json').write_text(json.dumps(archive))
        self.original = result('source-run')
        self.original['tool']['executable'] = '/assigned/axe'
        self.original['environment'] = {'udid': 'original-device', 'developerDir': '/original/Xcode'}
        self.original['app'] = {'project': '/original/Weather.xcodeproj', 'scheme': 'Weather',
                                'bundleId': 'original.weather'}
        self.original['preparation'] = {'status': 'ready'}
        self.original['execution'] = {'exitCode': 0, 'stopReason': None, 'cleanup': {'complete': True}}
        self.original['transcriptSHA256'] = digest(self.evidence / 'claude.jsonl')
        self.original['correctness']['checks'] += [{'id': name, 'status': 'passed'} for name in RUNNER_CHECKS]
        self.source = self.root / 'report.json'
        self.write_source()
        self.score = {'status': 'passed', 'correctness': {'status': 'passed', 'checks': [
            {'id': 'new-parser-proof', 'status': 'passed'}]},
            'metrics': copy.deepcopy(self.original['metrics']), 'warnings': []}

    def write_source(self):
        self.source.write_text(json.dumps(self.original))

    def run_rescore(self, name='rescored.json'):
        with patch('rescore.score_run', return_value=copy.deepcopy(self.score)) as score:
            value = rescore(self.source, self.root / name)
        return value, score

    def test_pass_preserves_inputs_metrics_and_original_bytes(self):
        before = {p: p.read_bytes() for p in [self.source, *self.evidence.iterdir()]}
        value, score = self.run_rescore()
        self.assertEqual(value['status'], 'passed')
        for field in ('tool', 'environment', 'app', 'metrics', 'execution', 'preparation'):
            self.assertEqual(value[field], self.original[field])
        for name, old in self.original['contract'].items():
            if name != 'scorerSHA256':
                self.assertEqual(value['contract'][name], old)
        self.assertEqual(value['sourceRunId'], 'source-run')
        self.assertEqual(value['sourceReportSHA256'], digest(self.source))
        self.assertEqual(value['previousScorerSHA256'], self.original['contract']['scorerSHA256'])
        self.assertEqual(score.call_args.kwargs['expected_setup']['runDirectory'], '/original/runner/directory')
        self.assertEqual(score.call_args.kwargs['expected_executable'], '/assigned/axe')
        for path, contents in before.items():
            self.assertEqual(path.read_bytes(), contents)

    def test_same_source_and_scorer_have_deterministic_report(self):
        first, _ = self.run_rescore('first.json')
        second, _ = self.run_rescore('second.json')
        self.assertEqual(first, second)
        self.assertEqual((self.root / 'first.json').read_bytes(), (self.root / 'second.json').read_bytes())

    def test_changed_metrics_remain_unverified_and_original_costs_retained(self):
        self.score['metrics']['totalCalls'] -= 1
        value, _ = self.run_rescore()
        self.assertEqual(value['status'], 'unverified')
        self.assertEqual(value['metrics'], self.original['metrics'])

    def test_missing_cleanup_cannot_promote_original_run(self):
        self.original['execution'].pop('cleanup')
        self.write_source()
        value, _ = self.run_rescore()
        self.assertEqual(value['status'], 'unverified')

    def test_incomplete_execution_cannot_promote_original_run(self):
        for index, change in enumerate(({'exitCode': 143}, {'stopReason': 'KeyboardInterrupt'},
                                         {'cleanup': {'complete': False}})):
            self.original['execution'] = {'exitCode': 0, 'stopReason': None, 'cleanup': {'complete': True}, **change}
            self.write_source()
            value, _ = self.run_rescore('bad-' + str(index) + '.json')
            self.assertEqual(value['status'], 'unverified')

    def test_blocked_original_stays_blocked(self):
        self.original['status'] = self.original['correctness']['status'] = 'blocked'
        self.write_source()
        value, _ = self.run_rescore()
        self.assertEqual(value['status'], 'blocked')

    def test_missing_original_runner_check_stays_unverified(self):
        self.original['correctness']['checks'] = self.original['correctness']['checks'][:-1]
        self.write_source()
        value, _ = self.run_rescore()
        self.assertEqual(value['status'], 'unverified')

    def test_corrupt_archive_is_rejected_before_scoring(self):
        (self.evidence / 'result.json').write_text('changed')
        with patch('rescore.score_run') as score, self.assertRaisesRegex(ValueError, 'hash mismatch'):
            rescore(self.source, self.root / 'rescored.json')
        score.assert_not_called()
        self.assertFalse((self.root / 'rescored.json').exists())

    def test_manifest_cannot_override_original_transcript_hash(self):
        (self.evidence / 'claude.jsonl').write_text('changed')
        manifest = self.evidence / 'archive.json'
        archive = json.loads(manifest.read_text())
        archive['sha256']['claude.jsonl'] = digest(self.evidence / 'claude.jsonl')
        manifest.write_text(json.dumps(archive))
        with self.assertRaisesRegex(ValueError, 'original report'):
            self.run_rescore()

    def test_existing_output_and_source_cannot_be_overwritten(self):
        output = self.root / 'rescored.json'
        output.write_text('preserved')
        for path in (output, self.source):
            with self.assertRaises(FileExistsError):
                rescore(self.source, path)
        self.assertEqual(output.read_text(), 'preserved')

    def test_output_cannot_add_files_to_original_evidence(self):
        output = self.evidence / 'new-report.json'
        with self.assertRaisesRegex(ValueError, 'outside the original evidence'):
            rescore(self.source, output)
        self.assertFalse(output.exists())

    def test_already_rescored_report_cannot_change_provenance_for_same_run_id(self):
        self.run_rescore()
        with self.assertRaisesRegex(ValueError, 'already uses the current scorer'):
            rescore(self.root / 'rescored.json', self.root / 'rescored-again.json')
        self.assertFalse((self.root / 'rescored-again.json').exists())


if __name__ == '__main__':
    unittest.main()
