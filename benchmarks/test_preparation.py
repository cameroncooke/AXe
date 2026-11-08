"""Offline checks of preparation with public CLI response shapes."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from preparation import ContactPreparation, ReminderPreparation, prepare
from adapters import sha256_file


CONTACT = {
    'applicationLabel': 'Contacts', 'expectedScreen': [402, 874],
    'baselineRows': ['Baseline contact'], 'maximumScrolls': 0,
    'approvedRecord': 'MCP Contact Benchmark',
    'rowLabel': 'MCP Contact Benchmark, XcodeBuildMCP Benchmark',
    'fields': {'firstName': 'MCP', 'lastName': 'Contact Benchmark',
               'organization': 'XcodeBuildMCP Benchmark', 'phoneDigits': '5550104242',
               'email': 'mcp.contact.benchmark@example.com'},
}
REMINDERS = {
    'applicationLabel': 'Reminders', 'expectedScreen': [402, 874],
    'homeMarker': 'My Lists', 'baselineListRows': ['Reminders, 0 reminders'],
    'ownedListRow': 'MCP Benchmark List, 1 reminder',
    'ownedReminderRows': ['File report benchmark, Incomplete', 'Buy milk benchmark, Completed',
                          'Call team benchmark, Completed'],
}


def raw(app, entries):
    children = [{'type': kind, 'AXLabel': label, 'pid': 321, 'enabled': True,
                 'frame': {'x': 20, 'y': 80 + index * 50, 'width': 300, 'height': 40}}
                for index, (kind, label) in enumerate(entries)]
    return [{'type': 'Application', 'AXLabel': app, 'pid': 321,
             'frame': {'x': 0, 'y': 0, 'width': 402, 'height': 874}, 'children': children}]


def contact_list(owned=False):
    labels = CONTACT['baselineRows'] + ([CONTACT['rowLabel']] if owned else [])
    return raw('Contacts', [('GenericElement', label) for label in labels])


def card():
    return raw('Contacts', [('Button', 'Back'), ('Button', 'Edit')] + [
        ('StaticText', value) for value in ['MCP Contact Benchmark', 'XcodeBuildMCP Benchmark',
                                           '(555) 010-4242', 'mcp.contact.benchmark@example.com']])


def capture(labels=(), buttons=(), reminders=(), lists=()):
    rows = [f't{n}||text|{label}|' for n, label in enumerate(labels)]
    rows += [f'b{n}|tap|button|{label}|' for n, label in enumerate(buttons)]
    rows += [f'r{n}|tap|button|{label}||apple-reminderkit://REMCDReminder/{n}'
             for n, label in enumerate(reminders)]
    rows += [f'l{n}|tap|button|{label}||<x-apple-reminderkit://REMCDList/{n}>'
             for n, label in enumerate(lists)]
    return {'applicationPID': 321, 'targets': rows}


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.args = SimpleNamespace(axe=Path('/not-executed/axe'), out=Path(self.folder.name),
                                    udid='fixture-device', timeout=1, allow_cleanup=True,
                                    env={'DEVELOPER_DIR': '/fixture/ConfiguredXcode/Contents/Developer'},
                                    expected_pid=321)

    def run_contact(self, trees, timeout_input=False, frames=()):
        worker = ContactPreparation(self.args, CONTACT)
        pending = iter(trees)
        pixels = iter(frames)

        def execute(argv, **kwargs):
            self.assertIs(kwargs['env'], self.args.env)
            if argv[1] == 'screenshot':
                Path(argv[argv.index('--output') + 1]).write_bytes(next(pixels, b'still'))
                return subprocess.CompletedProcess(argv, 0, b'', b'')
            if argv[1] == 'describe-ui':
                payload = json.dumps(next(pending)).encode()
            else:
                if timeout_input:
                    raise subprocess.TimeoutExpired(argv, 1)
                payload = b'OK'
            return subprocess.CompletedProcess(argv, 0, payload, b'')

        with patch('preparation.subprocess.run', side_effect=execute):
            worker.run()
        return worker

    def test_clean_list_needs_no_input(self):
        self.args.allow_cleanup = False
        worker = self.run_contact([contact_list()])
        self.assertEqual([call['phase'] for call in worker.calls], ['read'])

    def test_initial_launch_wait_observes_expected_app_and_pid_without_input(self):
        previous = raw('Reminders', [])
        wrong_process = contact_list()
        wrong_process[0]['pid'] = 999
        with patch('preparation.time.sleep') as sleep:
            worker = self.run_contact([previous, wrong_process, contact_list()])
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual([row['ready'] for row in worker.readiness_observations], [False, False, True])
        self.assertFalse(any(call['inputAttempted'] for call in worker.calls))

    def test_initial_wait_stops_at_deadline_without_input(self):
        worker = ContactPreparation(self.args, CONTACT)
        clock = [0.0]
        def sleep(seconds):
            clock[0] += seconds
        response = subprocess.CompletedProcess([], 0, json.dumps(raw('Reminders', [])).encode(), b'')
        with patch('preparation.time.monotonic', side_effect=lambda: clock[0]), \
                patch('preparation.time.sleep', side_effect=sleep), \
                patch('preparation.subprocess.run', return_value=response) as run:
            with self.assertRaisesRegex(ValueError, '10-second launch wait'):
                worker.run()
        self.assertEqual(clock[0], 10)
        self.assertEqual(run.call_count, 40)
        self.assertFalse(any(call['inputAttempted'] for call in worker.calls))
        self.assertLessEqual(run.call_args.kwargs['timeout'], 0.25)

    def test_wrong_process_after_input_stops_without_read_retry(self):
        changed = contact_list(True)
        changed[0]['pid'] = 999
        with patch('preparation.time.sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'process changed'):
                self.run_contact([card(), card(), changed])
        sleep.assert_not_called()
        calls = json.loads((self.args.out / 'calls.json').read_text())
        self.assertEqual([call['phase'] for call in calls if call['phase'] != 'screenshot'],
                         ['read', 'read', 'return-to-contact-list', 'read'])

    def test_prepare_passes_configured_environment_to_public_cli(self):
        binary = self.args.out / 'fixture-axe'
        binary.write_text('fixture, never executed')
        metadata = {'executable': str(binary), 'binarySHA256': sha256_file(binary)}
        response = subprocess.CompletedProcess([], 0, json.dumps(contact_list()).encode(), b'')
        with patch('adapters.inspect_tool', return_value=metadata), \
                patch('preparation.subprocess.run', return_value=response) as run:
            result = prepare('contacts', binary, 'fixture-device', self.args.out / 'prepare',
                             profile=CONTACT, env=self.args.env)
        self.assertEqual(result['status'], 'ready')
        self.assertEqual(run.call_count, 1)
        self.assertIs(run.call_args.kwargs['env'], self.args.env)

    def test_restored_owned_card_returns_to_list_before_delete(self):
        edit = raw('Contacts', [('TextField', 'First name'), ('Button', 'Delete Contact')])
        confirm = raw('Contacts', [('StaticText', 'Delete Contact'), ('Button', 'Delete')])
        worker = self.run_contact([card(), card(), contact_list(True), card(), edit, confirm, contact_list()])
        phases = [call['phase'] for call in worker.calls if call['inputAttempted']]
        self.assertEqual(phases, ['return-to-contact-list', 'open-owned-card', 'open-edit',
                                  'open-delete-confirmation', 'confirm-approved-delete'])

    def test_card_is_awaited_after_the_row_tap(self):
        # The row tap's first read can catch the push: the list is still in the tree and
        # only the row's name and organization are visible, not the card's phone or email.
        pushing = contact_list(True)
        pushing[0]['children'] += raw('Contacts', [
            ('StaticText', 'MCP Contact Benchmark'), ('StaticText', 'XcodeBuildMCP Benchmark')])[0]['children']
        edit = raw('Contacts', [('TextField', 'First name'), ('Button', 'Delete Contact')])
        confirm = raw('Contacts', [('StaticText', 'Delete Contact'), ('Button', 'Delete')])
        with patch('preparation.time.sleep') as sleep:
            worker = self.run_contact([contact_list(True), pushing, card(), edit, confirm, contact_list()])
        self.assertEqual(sleep.call_count, 1)
        phases = [call['phase'] for call in worker.calls if call['inputAttempted']]
        self.assertEqual(phases, ['open-owned-card', 'open-edit', 'open-delete-confirmation',
                                  'confirm-approved-delete'])

    def test_list_is_awaited_after_returning_from_the_restored_card(self):
        # Back's first read can still show the card while it pops.
        edit = raw('Contacts', [('TextField', 'First name'), ('Button', 'Delete Contact')])
        confirm = raw('Contacts', [('StaticText', 'Delete Contact'), ('Button', 'Delete')])
        with patch('preparation.time.sleep') as sleep:
            worker = self.run_contact([card(), card(), card(), contact_list(True), card(), edit, confirm,
                                       contact_list()])
        self.assertEqual(sleep.call_count, 1)
        phases = [call['phase'] for call in worker.calls if call['inputAttempted']]
        self.assertEqual(phases, ['return-to-contact-list', 'open-owned-card', 'open-edit',
                                  'open-delete-confirmation', 'confirm-approved-delete'])

    def test_presented_confirmation_is_tapped_only_once_the_display_holds(self):
        # The tree shows a presented sheet at its final frame while it is still animating in,
        # and a tap then is accepted and ignored. Only the pixels show the presentation.
        edit = raw('Contacts', [('TextField', 'First name'), ('Button', 'Delete Contact')])
        confirm = raw('Contacts', [('StaticText', 'Delete Contact'), ('Button', 'Delete')])
        frames = [b'still', b'still', b'still', b'still',  # the card, then the edit form
                  b'rising', b'risen', b'risen', b'risen',  # the confirmation presents, then holds
                  b'still', b'still']
        with patch('preparation.time.sleep') as sleep:
            worker = self.run_contact([contact_list(True), card(), edit, confirm, contact_list()],
                                      frames=frames)
        self.assertEqual(sleep.call_count, 1)
        phases = [call['phase'] for call in worker.calls]
        delete = phases.index('confirm-approved-delete')
        self.assertEqual(phases[delete - 5:delete],
                         ['screenshot', 'screenshot', 'screenshot', 'screenshot', 'read'])
        self.assertFalse(any(call['inputAttempted'] for call in worker.calls
                             if call['phase'] == 'screenshot'))

    def test_scroll_is_awaited_until_the_layout_holds_before_the_delete_tap(self):
        # A fling can still be bouncing at the first read; a tap then only stops the scroll.
        def form(delete_y=None):
            tree = raw('Contacts', [('TextField', 'First name')])
            if delete_y is not None:
                tree[0]['children'].append({'type': 'Button', 'AXLabel': 'Delete Contact', 'pid': 321,
                                            'enabled': True, 'frame': {'x': 16, 'y': delete_y,
                                                                       'width': 370, 'height': 51}})
            return tree
        confirm = raw('Contacts', [('StaticText', 'Delete Contact'), ('Button', 'Delete')])
        self.profile = dict(CONTACT, maximumScrolls=1)
        worker = ContactPreparation(self.args, self.profile)
        pending = iter([contact_list(True), card(), form(), form(776.7), form(772), form(772),
                        confirm, contact_list()])

        def execute(argv, **kwargs):
            if argv[1] == 'screenshot':
                Path(argv[argv.index('--output') + 1]).write_bytes(b'still')
            payload = json.dumps(next(pending)).encode() if argv[1] == 'describe-ui' else b'OK'
            return subprocess.CompletedProcess(argv, 0, payload, b'')

        with patch('preparation.time.sleep') as sleep, \
                patch('preparation.subprocess.run', side_effect=execute):
            worker.run()
        self.assertEqual(sleep.call_count, 2)
        delete_tap = next(call['argv'] for call in worker.calls
                          if call['phase'] == 'open-delete-confirmation')
        self.assertEqual(float(delete_tap[delete_tap.index('-y') + 1]), 772 + 51 / 2)

    def test_card_that_never_arrives_stops_without_repeating_the_tap(self):
        worker = ContactPreparation(self.args, CONTACT)
        clock = [0.0]
        reads = [0]

        def sleep(seconds):
            clock[0] += seconds

        def execute(argv, **kwargs):
            if argv[1] == 'screenshot':
                Path(argv[argv.index('--output') + 1]).write_bytes(b'still')
            if argv[1] == 'describe-ui':
                reads[0] += 1
                tree = contact_list(True)
                return subprocess.CompletedProcess(argv, 0, json.dumps(tree).encode(), b'')
            return subprocess.CompletedProcess(argv, 0, b'OK', b'')

        with patch('preparation.time.monotonic', side_effect=lambda: clock[0]), \
                patch('preparation.time.sleep', side_effect=sleep), \
                patch('preparation.subprocess.run', side_effect=execute):
            with self.assertRaisesRegex(ValueError, 'card name'):
                worker.run()
        self.assertEqual([call['phase'] for call in worker.calls if call['inputAttempted']],
                         ['open-owned-card'])
        self.assertEqual(clock[0], 10)
        self.assertEqual(reads[0], 42)

    def test_restored_card_is_judged_once_its_tree_holds(self):
        # A relaunched app is frontmost before its tree is complete: the first read of the
        # restored card can lack the phone row. Preparation judges the card once a read repeats.
        partial = card()
        partial[0]['children'] = [child for child in partial[0]['children'] if child['AXLabel'] != '(555) 010-4242']
        edit = raw('Contacts', [('TextField', 'First name'), ('Button', 'Delete Contact')])
        confirm = raw('Contacts', [('StaticText', 'Delete Contact'), ('Button', 'Delete')])
        with patch('preparation.time.sleep'):
            worker = self.run_contact([partial, card(), card(), contact_list(True), card(), edit, confirm,
                                       contact_list()])
        phases = [call['phase'] for call in worker.calls if call['inputAttempted']]
        self.assertEqual(phases, ['return-to-contact-list', 'open-owned-card', 'open-edit',
                                  'open-delete-confirmation', 'confirm-approved-delete'])

    def test_restored_card_with_wrong_fields_stops_before_input(self):
        wrong = card()
        wrong[0]['children'][-1]['AXLabel'] = 'other@example.com'
        with self.assertRaisesRegex(ValueError, 'email differs'):
            self.run_contact([wrong, wrong])
        calls = json.loads((self.args.out / 'calls.json').read_text())
        self.assertFalse(any(call['inputAttempted'] for call in calls))

    def test_returned_list_with_extra_record_stops_before_delete(self):
        extra = contact_list(True)
        extra[0]['children'].append(copy.deepcopy(extra[0]['children'][0]))
        with self.assertRaisesRegex(ValueError, 'Initial list'):
            self.run_contact([card(), card(), extra])
        calls = json.loads((self.args.out / 'calls.json').read_text())
        self.assertEqual([call['phase'] for call in calls if call['inputAttempted']], ['return-to-contact-list'])

    def test_input_timeout_is_recorded_and_not_retried(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_contact([card(), card()], timeout_input=True)
        calls = json.loads((self.args.out / 'calls.json').read_text())
        self.assertEqual(len([call for call in calls if call['phase'] != 'screenshot']), 3)
        self.assertTrue(calls[-1]['inputOutcomeUnknown'])

    def run_reminders(self, captures):
        worker = ReminderPreparation(self.args, REMINDERS)
        pending = iter(captures)

        def execute(argv, **kwargs):
            self.assertIs(kwargs['env'], self.args.env)
            value = {'data': {'capture': next(pending)}} if '--agent' in argv else raw('Reminders', [])
            return subprocess.CompletedProcess(argv, 0, json.dumps(value).encode(), b'')

        with patch('preparation.subprocess.run', side_effect=execute):
            worker.run()
        return worker

    def test_hidden_completed_reminders_are_shown_then_all_records_checked(self):
        detail = capture(['MCP Benchmark List'], ['More'], REMINDERS['ownedReminderRows'])
        initial = capture(['MCP Benchmark List'], ['More'], ['File report benchmark, Incomplete'])
        home = capture(['My Lists'], ['Scheduled, 0 reminders', 'All, 0 reminders'],
                       lists=['Reminders, 0 reminders'])
        worker = self.run_reminders([initial, capture(buttons=['Show Completed']), detail,
                                    capture(buttons=['Delete List']),
                                    capture(['Delete list “MCP Benchmark List”?'], ['Delete']), home, home])
        labels = [call['argv'][call['argv'].index('--label') + 1]
                  for call in worker.calls if '--label' in call['argv']]
        self.assertEqual(labels, ['More', 'Show Completed', 'More', 'Delete List', 'Delete'])

    def test_overview_is_awaited_after_the_delete_confirmation(self):
        # The delete confirmation returns before the detail pops; the overview arrives a read later.
        detail = capture(['MCP Benchmark List'], ['More'], REMINDERS['ownedReminderRows'])
        popping = capture(['2 Completed'], ['Back', 'New Reminder'])
        home = capture(['My Lists'], ['Scheduled, 0 reminders', 'All, 0 reminders'],
                       lists=['Reminders, 0 reminders'])
        with patch('preparation.time.sleep') as sleep:
            worker = self.run_reminders([detail, capture(buttons=['Delete List']),
                                        capture(['Delete list “MCP Benchmark List”?'], ['Delete']),
                                        popping, popping, home])
        self.assertEqual(sleep.call_count, 1)
        phases = [call['phase'] for call in worker.calls][-3:]
        self.assertTrue(phases[0].startswith('tap-'), phases)
        self.assertEqual(phases[1:], ['read', 'read'])
        self.assertIn('Owned list absent; expected other list rows preserved.', worker.checks)

    def test_opening_detail_is_awaited_before_its_rows_are_judged(self):
        # The owned list's tap reply still shows the overview with the detail arriving; its rows
        # are judged only once the detail toolbar (More) is present.
        home = capture(['My Lists'], ['Scheduled, 0 reminders', 'All, 0 reminders'],
                       lists=['Reminders, 0 reminders', 'MCP Benchmark List, 1 reminder'])
        opening = capture(['My Lists', 'MCP Benchmark List'], ['Add List', 'New Reminder'],
                          ['File report benchmark, Incomplete'])
        detail = capture(['MCP Benchmark List'], ['More'], REMINDERS['ownedReminderRows'])
        settled = capture(['My Lists'], ['Scheduled, 0 reminders', 'All, 0 reminders'],
                          lists=['Reminders, 0 reminders'])
        with patch('preparation.time.sleep') as sleep:
            worker = self.run_reminders([home, opening, detail, capture(buttons=['Delete List']),
                                        capture(['Delete list “MCP Benchmark List”?'], ['Delete']),
                                        settled, settled])
        self.assertEqual(sleep.call_count, 1)
        labels = [call['argv'][call['argv'].index('--label') + 1]
                  for call in worker.calls if '--label' in call['argv']]
        self.assertEqual(labels, ['MCP Benchmark List, 1 reminder', 'More', 'Delete List', 'Delete'])

    def test_unexpected_reminder_is_not_deleted(self):
        with self.assertRaisesRegex(ValueError, 'Unexpected reminder'):
            self.run_reminders([capture(['MCP Benchmark List'], ['More'], ['Unrelated, Incomplete'])])
        calls = json.loads((self.args.out / 'calls.json').read_text())
        self.assertFalse(any(call['inputAttempted'] for call in calls))


if __name__ == '__main__':
    unittest.main()
