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
        self.config = {'simulator': '419D3218-79E5-46DE-80C0-E58126A88252',
                       'developerDir': '/fixture/Xcode/Contents/Developer',
                       'xcodebuildmcp': str(self.root / 'XcodeBuildMCP'), 'model': 'fixture-model'}
        self.app = {'directory': str(self.root), 'bundleId': 'fixture.system-app',
                    'project': str(self.root / 'Weather.xcodeproj'), 'scheme': 'Weather'}
        # A vendor skill as a tool ships it, with a reference file.
        self.vendor = self.root / 'vendor-skill'
        (self.vendor / 'references').mkdir(parents=True)
        (self.vendor / 'SKILL.md').write_text('---\nname: vendor\n---\nRun `tool screen`.\n')
        (self.vendor / 'references' / 'commands.md').write_text('tool tap --label X\n')

    def identity(self, tool):
        binary = self.root / tool
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o700)
        return {'executable': str(binary)}

    def suite(self, tool, scenario='contacts', name=None):
        output = self.root / (name or ('case-' + tool + '-' + scenario))
        source = None if tool == 'axe' else self.vendor
        return output, make_suite(self.config, scenario, tool, self.identity(tool), self.app, output, skill_source=source)

    def test_each_tool_may_redirect_only_into_its_own_run_directory(self):
        for tool in ('axe', 'rocketsim', 'flowdeck'):
            with self.subTest(tool=tool):
                output, value = self.suite(tool)
                rules = [entry for entry in value['claude']['allowedTools'] if entry.startswith('Edit')]
                root = 'Edit(/' + self.config['xcodebuildmcp'] + '/out.nosync/claude-benchmarks/' + output.name
                temporary = ['Edit(//' + base + '/*.' + suffix + ')' for base in ('tmp', 'private/tmp')
                             for suffix in ('png', 'json', 'txt')]
                self.assertEqual(rules, [root + '/*/*.png)', root + '/*/*.json)', root + '/*/*.txt)'] + temporary)
                self.assertEqual(value['claude']['permissionMode'], 'default')
                self.assertFalse(any('**' in rule for rule in rules))
                self.assertIn('Run artifacts directory: {runDirectory}', value['claude']['appendSystemPrompt'])
                self.assertNotIn('Edit', value['claude']['tools'])

    def test_every_tool_gets_the_same_ui_only_instructions_and_no_setup_commands(self):
        prompts = {}
        for tool in ('axe', 'rocketsim', 'flowdeck'):
            for scenario in ('weather', 'contacts', 'reminders'):
                with self.subTest(tool=tool, scenario=scenario):
                    _, value = self.suite(tool, scenario)
                    prompt = value['claude']['appendSystemPrompt']
                    self.assertIn('This benchmark measures UI interaction only.', prompt)
                    self.assertIn('Do not build, install, launch or terminate apps.', prompt)
                    self.assertNotIn('xcodebuild', prompt)
                    self.assertNotIn('simctl', prompt)
                    allowed = value['claude']['allowedTools']
                    self.assertFalse(any('xcodebuild' in entry or 'simctl' in entry for entry in allowed), allowed)
                    shorts = {m['shortName'] for m in value['toolAnalysis']['matchers']}
                    self.assertFalse(any(name.startswith('setup.') for name in shorts), shorts)
                    prompts[(tool, scenario)] = prompt.replace(self.identity(tool)['executable'], 'CLI').replace(
                        '`' + tool + '`', '`CLI`')
        # Apart from the tool's own path and name, the instructions are identical for every tool.
        for scenario in ('weather', 'contacts', 'reminders'):
            self.assertEqual(len({prompts[(tool, scenario)] for tool in ('axe', 'rocketsim', 'flowdeck')}), 1)

    def test_axe_receives_the_shipped_skill_with_its_references(self):
        output, value = self.suite('axe')
        shipped = Path(__file__).resolve().parent.parent / 'Skills' / 'CLI' / 'axe'
        installed = output / 'skills' / 'axe'
        self.assertEqual(value['claude']['activateSkill'], 'axe')
        self.assertEqual(value['claude']['skillDirs'], [str(installed)])
        for source in shipped.rglob('*'):
            if source.is_file():
                relative = source.relative_to(shipped)
                self.assertEqual((installed / relative).read_bytes(), source.read_bytes(), str(relative))
        self.assertIn('`axe`', value['claude']['appendSystemPrompt'])

    def test_competitors_receive_their_official_skill_unedited(self):
        for tool in ('rocketsim', 'flowdeck'):
            with self.subTest(tool=tool):
                output, value = self.suite(tool)
                installed = output / 'skills' / tool
                self.assertEqual(value['claude']['activateSkill'], tool)
                self.assertEqual(value['claude']['skillDirs'], [str(installed)])
                for source in self.vendor.rglob('*'):
                    if source.is_file():
                        relative = source.relative_to(self.vendor)
                        self.assertEqual((installed / relative).read_bytes(), source.read_bytes(), str(relative))
                prompt = value['claude']['appendSystemPrompt']
                self.assertIn('`' + tool + '`', prompt)
                self.assertIn(self.identity(tool)['executable'], prompt)

    def test_a_competitor_without_its_skill_cannot_run(self):
        with self.assertRaisesRegex(ValueError, 'official flowdeck skill was not found'):
            make_suite(self.config, 'contacts', 'flowdeck', self.identity('flowdeck'), self.app,
                       self.root / 'case-missing', skill_source=self.root / 'absent')

    def test_checkout_glob_characters_are_literal(self):
        self.config['xcodebuildmcp'] = str(self.root / 'Xcode[1]*?')
        _, value = self.suite('axe', name='case-literal')
        rule = next(entry for entry in value['claude']['allowedTools'] if entry.startswith('Edit'))
        self.assertIn('Xcode\\[1\\]\\*\\?', rule)

    def test_relative_checkout_cannot_expand_permission_scope(self):
        self.config['xcodebuildmcp'] = 'relative-checkout'
        with self.assertRaisesRegex(ValueError, 'must be absolute'):
            make_suite(self.config, 'contacts', 'axe', self.identity('axe'), self.app, self.root / 'case-invalid')
        self.assertFalse((self.root / 'case-invalid').exists())


if __name__ == '__main__':
    unittest.main()
