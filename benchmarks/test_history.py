"""Offline checks for durable report history. No simulator or model calls."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import baselines
import history
from test_baselines import result


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.sources = self.root / 'external-artifacts'
        self.sources.mkdir()
        self.history = self.root / 'history'

    def tearDown(self):
        self.temporary.cleanup()

    def save(self, value):
        source = self.sources / (value['runId'].replace('/', '_') + '.json')
        source.write_text(json.dumps(value, indent=3) + '\n\n', encoding='utf-8')
        return source

    def test_exact_bytes_and_contract_are_preserved_without_external_dependency(self):
        value = result()
        source = self.save(value)
        original = source.read_bytes()
        receipt = history.import_report(source, self.history)
        retained = Path(receipt['report'])
        self.assertEqual(retained.read_bytes(), original)
        self.assertEqual(baselines.comparison_key(baselines.read_result(retained)),
                         baselines.comparison_key(value))
        shutil.rmtree(self.sources)
        rows = history.list_history(self.history)
        self.assertTrue(rows['indexCurrent'])
        self.assertEqual(rows['runs'][0]['tool']['version'], '1.0')
        self.assertTrue(baselines.compare_results(baselines.read_result(retained), value)['comparable'])

    def test_duplicate_is_idempotent_and_collision_does_not_mutate_history(self):
        source = self.save(result())
        history.import_report(source, self.history)
        before = {file.relative_to(self.history): file.read_bytes()
                  for file in self.history.rglob('*') if file.is_file()}
        self.assertEqual(history.import_report(source, self.history)['status'], 'already-recorded')
        source.write_text(json.dumps(result(calls=1)))
        with self.assertRaisesRegex(ValueError, 'different report bytes'):
            history.import_report(source, self.history)
        after = {file.relative_to(self.history): file.read_bytes()
                 for file in self.history.rglob('*') if file.is_file()}
        self.assertEqual(before, after)

    def test_external_evidence_provenance_is_explicit_and_raw_files_not_copied(self):
        evidence = self.sources / 'evidence'
        evidence.mkdir()
        archive = evidence / 'archive.json'
        archive.write_text('{"sha256": {}}')
        (evidence / 'private-transcript.jsonl').write_text('not copied')
        value = result()
        value['transcriptSHA256'] = 'c' * 64
        source = self.save(value)
        receipt = history.import_report(source, self.history)
        folder = Path(receipt['report']).parent
        self.assertEqual({p.name for p in folder.iterdir()}, {'report.json', 'manifest.json'})
        provenance = json.loads((folder / 'manifest.json').read_text())['provenance']
        self.assertFalse(provenance['rawEvidenceIncluded'])
        self.assertEqual(provenance['sourceReportSHA256'], hashlib.sha256(source.read_bytes()).hexdigest())
        self.assertEqual(provenance['evidenceArchiveSHA256'], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(provenance['transcriptSHA256'], 'c' * 64)
        self.assertIn('not revalidated', provenance['verification'])

    def test_changed_external_manifest_is_rejected(self):
        evidence = self.sources / 'evidence'
        evidence.mkdir()
        (evidence / 'archive.json').write_text('{}')
        value = result()
        value['evidenceArchiveSHA256'] = 'a' * 64
        with self.assertRaisesRegex(ValueError, 'archive differs'):
            history.import_report(self.save(value), self.history)
        self.assertFalse((self.history / 'first').exists())

    def test_summary_is_small_but_full_tool_metadata_is_preserved(self):
        value = result()
        value['tool'].update(runtimeFiles={'framework': 'c' * 64}, runtimeSHA256='d' * 64,
                             executable='/external/axe', mode='RS1',
                             companionApp={'version': '2', 'build': '7',
                                           'binarySHA256': 'e' * 64, 'executable': '/external/app'})
        receipt = history.import_report(self.save(value), self.history)
        tool = history.list_history(self.history)['runs'][0]['tool']
        self.assertNotIn('runtimeFiles', tool)
        self.assertNotIn('executable', tool)
        self.assertEqual(tool['runtimeSHA256'], 'd' * 64)
        self.assertEqual(tool['companionApp']['version'], '2')
        retained = json.loads(Path(receipt['report']).read_text())
        self.assertEqual(retained['tool'], value['tool'])

    def test_rescored_report_keeps_its_explicit_external_evidence_location(self):
        evidence = self.root / 'original-run' / 'evidence'
        evidence.mkdir(parents=True)
        archive = evidence / 'archive.json'
        archive.write_text('{}')
        value = result('first-rescore-0123456789ab')
        value.update(sourceRunId='first', sourceReport='/external/original/report.json',
                     sourceReportSHA256='a' * 64, evidenceDirectory=str(evidence),
                     evidenceArchiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest())
        source = self.save(value)
        receipt = history.import_report(source, self.history)
        manifest = json.loads((Path(receipt['report']).parent / 'manifest.json').read_text())
        self.assertEqual(manifest['provenance']['evidenceDirectory'], str(evidence))
        self.assertEqual(manifest['provenance']['evidenceArchiveSHA256'], value['evidenceArchiveSHA256'])
        self.assertEqual(json.loads(Path(receipt['report']).read_text()), value)

    def test_failed_and_blocked_runs_can_be_kept_without_becoming_baselines(self):
        value = result('blocked')
        value.update(status='blocked', contract={})
        value['correctness'] = {'status': 'unverified', 'checks': []}
        value['metrics'] = {'tokenStatus': 'unavailable'}
        history.import_report(self.save(value), self.history)
        self.assertEqual(history.list_history(self.history)['runs'][0]['status'], 'blocked')
        self.assertFalse((self.root / 'baselines.json').exists())

    def test_suite_import_supports_relative_and_absolute_report_paths(self):
        first = self.save(result('one'))
        second = self.save(result('two', tool='rocketsim'))
        (self.sources / 'summary.json').write_text(json.dumps({'runs': [
            {'report': first.name}, {'report': str(second)}]}))
        receipt = history.import_source(self.sources, self.history)
        self.assertEqual(len(receipt['imports']), 2)
        self.assertEqual([row['runId'] for row in history.list_history(self.history)['runs']], ['one', 'two'])

    def test_unsafe_run_id_and_invalid_result_are_rejected(self):
        for run_id in ('../outside', '.', '..', 'contains/slash'):
            with self.subTest(run_id=run_id), self.assertRaisesRegex(ValueError, 'Unsafe runId'):
                history.import_report(self.save(result(run_id)), self.history)
        value = result()
        value['schema'] = 'unknown'
        with self.assertRaises(ValueError):
            history.import_report(self.save(value), self.history)

    def test_local_report_or_manifest_tampering_is_detected(self):
        source = self.save(result())
        receipt = history.import_report(source, self.history)
        retained = Path(receipt['report'])
        retained.write_text(json.dumps(result(calls=1)))
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            history.list_history(self.history)
        retained.write_bytes(source.read_bytes())
        manifest = retained.parent / 'manifest.json'
        data = json.loads(manifest.read_text())
        data['provenance']['rawEvidenceIncluded'] = True
        manifest.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            history.list_history(self.history)

    def test_stale_index_does_not_hide_record_and_import_repairs_it(self):
        source = self.save(result())
        history.import_report(source, self.history)
        index = self.history / 'index.json'
        index.write_text('{}')
        listed = history.list_history(self.history)
        self.assertFalse(listed['indexCurrent'])
        self.assertEqual(len(listed['runs']), 1)
        history.import_report(source, self.history)
        self.assertTrue(history.list_history(self.history)['indexCurrent'])

    def test_symlink_root_and_source_are_rejected(self):
        source = self.save(result())
        link = self.root / 'source-link'
        link.symlink_to(source)
        with self.assertRaisesRegex(ValueError, 'regular report'):
            history.import_report(link, self.history)
        self.history.symlink_to(self.sources, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            history.import_report(source, self.history)

    def test_concurrent_imports_preserve_all_records(self):
        sources = [self.save(result('parallel-' + str(n))) for n in range(4)]
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda source: history.import_report(source, self.history), sources))
        listed = history.list_history(self.history)
        self.assertEqual(len(listed['runs']), 4)
        self.assertTrue(listed['indexCurrent'])


if __name__ == '__main__':
    unittest.main()
