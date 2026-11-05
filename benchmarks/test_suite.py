"""Offline suite permission checks. No model or simulator calls."""
from pathlib import Path
import tempfile
import unittest

from suite import make_suite


class SuitePermissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        binary = self.root / 'fixture-cli'
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o700)
        self.identity = {'executable': str(binary)}
        self.config = {'simulator': '419D3218-79E5-46DE-80C0-E58126A88252',
                       'developerDir': '/fixture/Xcode/Contents/Developer',
                       'xcodebuildmcp': str(self.root / 'XcodeBuildMCP'), 'model': 'fixture-model'}
        self.app = {'directory': str(self.root), 'bundleId': 'fixture.system-app'}

    def test_each_tool_has_only_its_unique_suite_png_edit_rule(self):
        for tool in ('axe', 'rocketsim', 'flowdeck'):
            with self.subTest(tool=tool):
                output = self.root / ('case-' + tool)
                value = make_suite(self.config, 'contacts', tool, self.identity, self.app, output)
                rules = [entry for entry in value['claude']['allowedTools'] if entry.startswith('Edit')]
                self.assertEqual(rules, ['Edit(/' + self.config['xcodebuildmcp']
                    + '/out.nosync/claude-benchmarks/' + output.name + '/*/*.png)'])
                self.assertEqual(value['claude']['permissionMode'], 'default')
                self.assertNotIn('**', rules[0])
                self.assertIn('Run artifacts directory: {runDirectory}', value['claude']['appendSystemPrompt'])
                self.assertNotIn('Edit', value['claude']['tools'])

    def test_checkout_glob_characters_are_literal(self):
        self.config['xcodebuildmcp'] = str(self.root / 'Xcode[1]*?')
        value = make_suite(self.config, 'contacts', 'axe', self.identity, self.app, self.root / 'case-literal')
        rule = next(entry for entry in value['claude']['allowedTools'] if entry.startswith('Edit'))
        self.assertIn('Xcode\\[1\\]\\*\\?', rule)

    def test_relative_checkout_cannot_expand_permission_scope(self):
        self.config['xcodebuildmcp'] = 'relative-checkout'
        with self.assertRaisesRegex(ValueError, 'must be absolute'):
            make_suite(self.config, 'contacts', 'axe', self.identity, self.app, self.root / 'case-invalid')
        self.assertFalse((self.root / 'case-invalid').exists())


if __name__ == '__main__':
    unittest.main()
