#!/usr/bin/env python3
"""docs/playground-testing.md states the case counts a full Playground run plans."""
import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parent.parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('playground_matrix', SCRIPTS / 'test-playground-matrix.py')
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)

DEVICES = ('iphone', 'ipad', 'duo')
DOC_GROUPS = {'Core controls': 'core-controls', 'Agent controls': 'agent-controls',
              'Keyboard and hardware': 'keyboard-hardware', 'Capture and recording': 'media',
              'Hinge and app layouts': 'hinge', 'Lifecycle, last': 'lifecycle'}


class PlaygroundDocCountTests(unittest.TestCase):
    """docs/playground-testing.md must state the counts a full run plans."""

    def setUp(self):
        self.counts = json.loads((SCRIPTS / 'playground-suite-counts.json').read_text())
        self.config = json.loads((SCRIPTS / 'playground-acceptance.json').read_text())
        self.doc = (ROOT / 'docs/playground-testing.md').read_text()

    def total(self, suites):
        return sum(self.counts[suite] for suite in suites)

    def test_total_row_matches_a_full_run(self):
        planned = [self.total(matrix.selected_suites(kind, 'all', self.config)) for kind in DEVICES]
        match = re.search(r'\| \*\*Total\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\* \| '
                          r'\*\*(\d+) case executions\*\* \|', self.doc)
        self.assertIsNotNone(match, 'docs/playground-testing.md has no total row')
        stated = [int(value) for value in match.groups()]
        self.assertEqual(stated, planned + [sum(planned)],
                         'Update the total row in docs/playground-testing.md to the counts a full run plans.')

    def test_group_rows_match_the_configured_groups(self):
        for label, group in DOC_GROUPS.items():
            with self.subTest(group=group):
                if group == 'lifecycle':
                    planned = [self.total(self.config['runLast']) if kind == 'duo' else 0 for kind in DEVICES]
                else:
                    planned = [self.total(self.config['groups'][group][kind]) for kind in DEVICES]
                match = re.search(r'\| ' + re.escape(label) + r' \| (\d+) \| (\d+) \| (\d+) \|', self.doc)
                self.assertIsNotNone(match, 'docs/playground-testing.md has no row for ' + label)
                self.assertEqual([int(value) for value in match.groups()], planned,
                                 'Update the ' + label + ' row in docs/playground-testing.md.')


if __name__ == '__main__':
    unittest.main()
