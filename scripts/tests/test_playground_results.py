#!/usr/bin/env python3
"""Use a genuine 27-instance/4-declaration trace; mutations must fail closed."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from playground_results import read_suite_result

FIXTURES = Path(__file__).resolve().parent / 'fixtures'


class PlaygroundResultTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.events = Path(self.directory.name) / 'events.jsonl'
        self.xml = Path(self.directory.name) / 'results.xml'
        self.records = [json.loads(line) for line in (FIXTURES / 'swift-testing-host-events-v0.jsonl').read_text().splitlines()]
        self.xml.write_bytes((FIXTURES / 'swift-testing-host-events-v0.xml').read_bytes())

    def result(self, records=None, expected=27):
        values = self.records if records is None else records
        self.events.write_text(''.join(json.dumps(record) + '\n' for record in values))
        return read_suite_result(self.xml, self.events, 'SelectedAXRetirement', expected)

    def index(self, kind):
        return next(i for i, record in enumerate(self.records)
                    if record['kind'] == 'event' and record['payload']['kind'] == kind)

    def inserted_event(self, kind):
        records = copy.deepcopy(self.records)
        at = self.index('testCaseEnded')
        event = copy.deepcopy(records[at])
        event['payload']['kind'] = kind
        records.insert(at, event)
        return records

    def test_genuine_trace_counts_instances_not_xml_declarations(self):
        result = self.result()
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual((result['started'], result['executed'], result['completedDeclarations']), (27, 27, 4))
        self.assertEqual(result['xml'], {'declarations': 4, 'skipped': 0, 'failed': 0})

    def test_private_extensions_are_not_required(self):
        def public(value):
            if isinstance(value, dict):
                return {key: public(item) for key, item in value.items() if not key.startswith('_')}
            if isinstance(value, list):
                return [public(item) for item in value]
            return value
        self.assertEqual(self.result(public(self.records))['status'], 'PASS')

    def test_missing_run_end_fails(self):
        result = self.result(self.records[:-1])
        self.assertEqual(result['status'], 'FAIL')
        self.assertFalse(result['completedRun'])

    def test_truncated_json_record_fails(self):
        self.result()
        data = self.events.read_bytes()
        self.events.write_bytes(data[:-12])
        self.assertEqual(read_suite_result(self.xml, self.events, 'SelectedAXRetirement', 27)['status'], 'FAIL')

    def test_end_without_start_fails(self):
        values = copy.deepcopy(self.records)
        del values[self.index('testCaseStarted')]
        self.assertEqual(self.result(values)['status'], 'FAIL')

    def test_duplicate_end_fails(self):
        self.assertEqual(self.result(self.inserted_event('testCaseEnded'))['status'], 'FAIL')

    def test_overlapping_case_starts_fail(self):
        self.assertEqual(self.result(self.inserted_event('testCaseStarted'))['status'], 'FAIL')

    def test_wrong_case_end_target_fails(self):
        values = copy.deepcopy(self.records)
        values[self.index('testCaseEnded')]['payload']['testID'] = 'undeclared-test'
        self.assertEqual(self.result(values)['status'], 'FAIL')

    def test_duplicate_run_fails(self):
        values = copy.deepcopy(self.records)
        at = self.index('runStarted')
        values.insert(at, copy.deepcopy(values[at]))
        self.assertEqual(self.result(values)['status'], 'FAIL')

    def test_recorded_issue_fails(self):
        values = self.inserted_event('issueRecorded')
        values[self.index('testCaseEnded')]['payload']['issue'] = {'isFailure': True, 'isKnown': False}
        result = self.result(values)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['issues'], 1)
        self.assertGreater(result['failed'], 0)

    def test_skip_fails(self):
        result = self.result(self.inserted_event('testSkipped'))
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['skipped'], 1)

    def test_cancellation_fails(self):
        result = self.result(self.inserted_event('testCaseCancelled'))
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['cancelled'], 1)

    def test_wrong_expanded_count_fails(self):
        result = self.result(expected=28)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['casesWithoutCompletedResults'], 1)

    def test_xml_failure_fails(self):
        tree = ET.parse(self.xml)
        ET.SubElement(next(tree.getroot().iter('testcase')), 'failure').text = 'real XML failure boundary'
        tree.write(self.xml)
        self.assertEqual(self.result()['status'], 'FAIL')

    def test_xml_declaration_mismatch_fails(self):
        tree = ET.parse(self.xml)
        suite = next(tree.getroot().iter('testsuite'))
        suite.remove(next(suite.iter('testcase')))
        tree.write(self.xml)
        self.assertEqual(self.result()['status'], 'FAIL')

    def test_unknown_schema_fails(self):
        values = copy.deepcopy(self.records)
        values[0]['version'] = '6.4'
        self.assertEqual(self.result(values)['status'], 'FAIL')


if __name__ == '__main__':
    unittest.main()
