"""Opt-in cleanup of exact benchmark records through observed public UI.

Preparation is outside the benchmark clock and never counts as a scenario pass.
Unexpected UI, ambiguous records or uncertain input stop without an input retry.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import subprocess
import time
from types import SimpleNamespace

from adapters import sha256_file as sha256


def require(condition, message):
    if not condition:
        raise ValueError(message)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def nodes(value):
    for node in value if isinstance(value, list) else [value]:
        require(isinstance(node, dict), 'Invalid raw accessibility node.')
        yield node
        yield from nodes(node.get('children', []))


def frame(node):
    result = tuple(node.get('frame', {}).get(key) for key in ('x', 'y', 'width', 'height'))
    require(all(type(v) in (int, float) and math.isfinite(v) for v in result)
            and result[2] > 0 and result[3] > 0, 'Invalid observed frame.')
    return result



class ContactPreparation:
    def __init__(self, args, profile):
        self.args, self.profile = args, profile
        self.calls, self.checks = [], []
        self.pid = None
        self.tree = []
        self.screen = None
        self.readiness_observations = []

    def call(self, argv, phase, timeout=None):
        folder = self.args.out / f'{len(self.calls):03d}-{phase}'
        folder.mkdir(parents=True)
        command = [str(self.args.axe), *argv, '--udid', self.args.udid]
        record = {'argv': command, 'phase': phase, 'inputAttempted': phase != 'read',
                  'stdout': str(folder / 'stdout'), 'stderr': str(folder / 'stderr')}
        started = time.monotonic()
        try:
            result = subprocess.run(command, capture_output=True,
                                    timeout=self.args.timeout if timeout is None else timeout,
                                    check=False, env=self.args.env)
            (folder / 'stdout').write_bytes(result.stdout)
            (folder / 'stderr').write_bytes(result.stderr)
            record.update(exitCode=result.returncode, stdoutSHA256=sha256(folder / 'stdout'))
            require(result.returncode == 0, 'CLI failed; stop. No input is retried.')
            return json.loads(result.stdout) if phase == 'read' else None
        except BaseException as error:
            record['failure'] = str(error)
            if isinstance(error, subprocess.TimeoutExpired):
                (folder / 'stdout').write_bytes(error.stdout or b'')
                (folder / 'stderr').write_bytes(error.stderr or b'')
                record['inputOutcomeUnknown'] = phase != 'read'
            raise
        finally:
            record['elapsedSeconds'] = time.monotonic() - started
            self.calls.append(record)
            write_json(folder / 'call.json', record)
            write_json(self.args.out / 'calls.json', self.calls)

    def read(self):
        value = self.call(['describe-ui'], 'read')
        self.accept_read(value)

    def read_initial(self):
        """Wait only for launch visibility. Never repeat input or post-input reads."""
        started = time.monotonic()
        deadline = started + 10
        while True:
            remaining = deadline - time.monotonic()
            require(remaining > 0, 'Expected app did not become frontmost within the 10-second launch wait.')
            value = self.call(['describe-ui'], 'read', timeout=min(self.args.timeout, remaining))
            require(isinstance(value, list) and len(value) == 1 and isinstance(value[0], dict)
                    and value[0].get('type') == 'Application', 'Expected one raw application tree.')
            root = value[0]
            ready = (root.get('AXLabel') == self.profile['applicationLabel']
                     and (self.args.expected_pid is None or root.get('pid') == self.args.expected_pid))
            self.readiness_observations.append({
                'call': len(self.calls), 'applicationLabel': root.get('AXLabel'),
                'applicationPID': root.get('pid'), 'expectedPID': self.args.expected_pid,
                'elapsedSeconds': time.monotonic() - started, 'ready': ready,
            })
            write_json(self.args.out / 'readiness.json', self.readiness_observations)
            if ready:
                self.accept_read(value)
                return
            remaining = deadline - time.monotonic()
            require(remaining > 0, 'Expected app did not become frontmost within the 10-second launch wait.')
            time.sleep(min(0.25, remaining))

    def accept_read(self, value):
        require(isinstance(value, list) and len(value) == 1,
                'Expected one raw application tree.')
        root = value[0]
        require(root.get('type') == 'Application'
                and root.get('AXLabel') == self.profile['applicationLabel'],
                'The expected app is not the observed frontmost application.')
        pid = root.get('pid')
        require(type(pid) is int and pid > 0 and (self.pid is None or pid == self.pid),
                'Application process changed; stop.')
        self.pid = pid
        x, y, width, height = frame(root)
        require((x, y) == (0, 0) and [width, height] == self.profile['expectedScreen'],
                'The approved screen size changed.')
        self.screen = (width, height)
        self.tree = list(nodes(value))
        require(all(n.get('pid') == pid for n in self.tree), 'Mixed application tree.')

    def centre(self, node):
        x, y, width, height = frame(node)
        point = (x + width / 2, y + height / 2)
        require(node.get('enabled') is True and node.get('hidden') is not True
                and 0 < point[0] < self.screen[0] and 0 < point[1] < self.screen[1],
                'Control centre is not enabled and inside the observed screen.')
        return point

    def button(self, label, required=True):
        # Duplicate native descriptions are accepted only at the same physical frame.
        found = {}
        for node in self.tree:
            if node.get('type') != 'Button' or node.get('AXLabel') != label:
                continue
            x, y, width, height = frame(node)
            if (node.get('enabled') is True and node.get('hidden') is not True
                    and 0 < x + width / 2 < self.screen[0]
                    and 0 < y + height / 2 < self.screen[1]):
                found[(x, y, width, height)] = node
        require(len(found) <= 1, 'More than one visible button frame matches ' + label)
        require(bool(found) or not required, 'No visible button matches ' + label)
        return next(iter(found.values())) if found else None

    def tap(self, node, phase):
        x, y = self.centre(node)
        self.call(['tap', '-x', str(x), '-y', str(y), '--tap-style', 'physical'], phase)
        self.read()

    def list_rows(self):
        return [n['AXLabel'] for n in self.tree if n.get('type') == 'GenericElement'
                and isinstance(n.get('AXLabel'), str) and n['AXLabel'] != '']

    def verify_card(self):
        fields = self.profile['fields']
        texts = [n.get('AXLabel') for n in self.tree if n.get('type') == 'StaticText']
        require(texts.count(fields['firstName'] + ' ' + fields['lastName']) == 1,
                'The saved card name does not prove the approved first and last names.')
        require(sum(' '.join((s or '').split()) == fields['organization'] for s in texts) == 1,
                'The saved organization differs.')
        require(sum(''.join(c for c in (s or '') if c.isdigit()) == fields['phoneDigits']
                    for s in texts) == 1, 'The saved phone differs.')
        require(texts.count(fields['email']) == 1, 'The saved email differs.')
        self.checks.append('All five approved fields observed on the saved card.')

    def run(self):
        self.read_initial()
        baseline = self.profile['baselineRows']
        require(len(set(baseline)) == len(baseline), 'Baseline row labels must be unique.')
        expected_with_owned = sorted(baseline + [self.profile['rowLabel']])
        if sorted(self.list_rows()) not in (sorted(baseline), expected_with_owned):
            # Relaunch can restore the saved card. Prove its identity before leaving it,
            # then verify the whole list before any destructive action.
            back = self.button('Back', required=False)
            require(back is not None, 'Expected contact list or owned saved card is not visible.')
            self.verify_card()
            self.tap(back, 'return-to-contact-list')
        if sorted(self.list_rows()) == sorted(baseline):
            self.checks.append('Approved contact absent; complete expected baseline rows observed.')
            return
        require(self.args.allow_cleanup, 'Owned contact exists; cleanup authorization is required.')
        require(sorted(self.list_rows()) == expected_with_owned,
                'Initial list does not contain exactly expected baseline rows and one owned record.')
        matches = [n for n in self.tree if n.get('type') == 'GenericElement'
                   and n.get('AXLabel') == self.profile['rowLabel']]
        require(len(matches) == 1, 'The owned whole-card row is not unique.')
        self.tap(matches[0], 'open-owned-card')
        self.verify_card()
        self.tap(self.button('Edit'), 'open-edit')
        require(any(n.get('type') == 'TextField' for n in self.tree), 'Edit form not observed.')
        for count in range(self.profile['maximumScrolls'] + 1):
            target = self.button('Delete Contact', required=False)
            if target is not None:
                break
            require(count < self.profile['maximumScrolls'], 'Delete Contact was not visible.')
            before = [(n.get('type'), n.get('AXLabel'), n.get('frame')) for n in self.tree]
            # Normal scrolling uses current application dimensions, never saved coordinates.
            width, height = self.screen
            self.call(['gesture', 'scroll-up', '--screen-width', str(width),
                       '--screen-height', str(height), '--duration', '0.5',
                       '--post-delay', '1'], 'scroll-edit')
            self.read()
            require(before != [(n.get('type'), n.get('AXLabel'), n.get('frame'))
                               for n in self.tree], 'Scroll produced no observed layout change.')
        self.tap(target, 'open-delete-confirmation')
        require(any(n.get('AXLabel') == 'Delete Contact' for n in self.tree)
                and self.button('Delete') is not None,
                'Expected Delete Contact confirmation is absent.')
        self.tap(self.button('Delete'), 'confirm-approved-delete')
        require(sorted(self.list_rows()) == sorted(baseline),
                'Final list differs from the expected baseline rows; no further action is allowed.')
        require(not any(self.profile['approvedRecord'] in (n.get('AXLabel') or '')
                        for n in self.tree), 'Owned record is still present.')
        self.checks.append('Owned contact absent; exact expected baseline row labels preserved.')


class ReminderPreparation(ContactPreparation):
    """Only the complete three-item benchmark list can be removed."""

    def run_agent(self, argv, phase='read'):
        # Agent input returns a JSON capture. Log it as input, not as an observation.
        folder = self.args.out / f'{len(self.calls):03d}-{phase}'
        folder.mkdir(parents=True)
        command = [str(self.args.axe), *argv, '--udid', self.args.udid]
        record = {'argv': command, 'phase': phase, 'inputAttempted': phase != 'read'}
        started = time.monotonic()
        try:
            completed = subprocess.run(command, capture_output=True, timeout=self.args.timeout,
                                       check=False, env=self.args.env)
            (folder / 'stdout').write_bytes(completed.stdout)
            (folder / 'stderr').write_bytes(completed.stderr)
            record['exitCode'] = completed.returncode
            require(completed.returncode == 0, 'CLI failed; no input is retried.')
            result = json.loads(completed.stdout)
            require(not result.get('didError'), 'Agent action refused; no input is retried.')
            capture = result['data']['capture']
            pid = capture['applicationPID']
            require(type(pid) is int and pid > 0 and (self.pid is None or self.pid == pid),
                    'Application process changed.')
            self.pid = pid
            require(not capture.get('nextRowOffset'), 'Preparation needs a complete capture, not a page.')
            require(not capture.get('page', {}).get('hasMore'), 'Preparation capture is incomplete.')
            return capture
        except BaseException as error:
            record['failure'] = str(error)
            if isinstance(error, subprocess.TimeoutExpired):
                (folder / 'stdout').write_bytes(error.stdout or b'')
                (folder / 'stderr').write_bytes(error.stderr or b'')
                record['inputOutcomeUnknown'] = phase != 'read'
            raise
        finally:
            record['elapsedSeconds'] = time.monotonic() - started
            self.calls.append(record)
            write_json(folder / 'call.json', record)
            write_json(self.args.out / 'calls.json', self.calls)

    @staticmethod
    def rows(capture):
        return [row.split('|') for key in ('targets', 'scroll', 'text', 'rows')
                for row in capture.get(key, []) if isinstance(row, str)]

    def has(self, capture, label):
        return any(len(row) >= 4 and row[3] == label for row in self.rows(capture))

    def owned_rows(self, capture):
        return [row[3] for row in self.rows(capture)
                if len(row) >= 4 and any('apple-reminderkit://REMCDReminder/' in field for field in row)]

    def tap_label(self, capture, label):
        matches = [row for row in self.rows(capture) if len(row) >= 4
                   and 'tap' in row[1].split(',') and row[2] == 'button' and row[3] == label]
        require(len(matches) == 1, 'Expected exactly one observed button: ' + label)
        return self.run_agent(['tap', '--agent', '--view', 'full', '--expected-pid', str(self.pid),
                               '--label', label, '--element-type', 'Button', '--tap-style', 'simulator'],
                              'tap-' + str(len(self.calls)))

    def require_home(self, capture, owned_present):
        # A supplied full expected list inventory prevents an absence claim from a detail page.
        labels = [row[3] for row in self.rows(capture) if len(row) >= 4]
        require(self.has(capture, self.profile['homeMarker']), 'Expected list overview is not visible.')
        expected = list(self.profile['baselineListRows'])
        if owned_present:
            expected.append(self.profile['ownedListRow'])
        actual = [row[3] for row in self.rows(capture) if len(row) >= 6 and row[2] == 'button'
                  and any('x-apple-reminderkit://REMCDList/' in field for field in row[5:])]
        require(sorted(actual) == sorted(expected), 'Full expected list inventory does not match.')
        require(owned_present or not any('MCP Benchmark List' in label for label in labels),
                'Benchmark list is still present.')

    def await_home(self, attempts=10, pause=0.5):
        """Read until the list overview is visible, within a bound.

        After the delete confirmation the app pops its list detail to the overview with an
        animation; a single read taken as soon as the tap returns can still show the detail.
        Preparation runs outside the benchmark clock, so this wait costs nothing measured.
        """
        for attempt in range(attempts):
            capture = self.run_agent(['describe-ui', '--agent', '--view', 'full'])
            if self.has(capture, self.profile['homeMarker']) or attempt == attempts - 1:
                return capture
            time.sleep(pause)

    def run(self):
        # First establish the correct app and dimensions from its raw public hierarchy.
        self.read_initial()
        capture = self.run_agent(['describe-ui', '--agent', '--view', 'full'])
        if self.has(capture, self.profile['homeMarker']):
            owned = self.has(capture, self.profile['ownedListRow'])
            self.require_home(capture, owned)
            if not owned:
                self.checks.append('Owned list absent; complete expected list overview observed.')
                return
            require(self.args.allow_cleanup, 'Owned list exists; cleanup authorization is required.')
            capture = self.tap_label(capture, self.profile['ownedListRow'])
        else:
            require(self.args.allow_cleanup, 'Cleanup authorization is required.')
        require(self.has(capture, 'MCP Benchmark List'), 'Owned list detail is not visible.')
        owned = self.owned_rows(capture)
        expected = self.profile['ownedReminderRows']
        if sorted(owned) != sorted(expected):
            # Hidden completed rows are a UI presentation choice. Only expose them
            # when all observed records already match the approved incomplete set.
            incomplete = [row for row in expected if row.endswith(', Incomplete')]
            require(sorted(owned) == sorted(incomplete),
                    'Unexpected reminder records; no preparation input is permitted.')
            capture = self.tap_label(capture, 'More')
            capture = self.tap_label(capture, 'Show Completed')
            require(self.has(capture, 'MCP Benchmark List'), 'Owned list changed after Show Completed.')
            owned = self.owned_rows(capture)
        require(sorted(owned) == sorted(self.profile['ownedReminderRows']),
                'Exact completed benchmark reminders were not observed; no deletion is permitted.')
        self.checks.append('Exact three approved benchmark reminder rows observed.')
        capture = self.tap_label(capture, 'More')
        capture = self.tap_label(capture, 'Delete List')
        require(self.has(capture, 'Delete list “MCP Benchmark List”?'), 'Expected list delete confirmation absent.')
        self.tap_label(capture, 'Delete')
        capture = self.await_home()
        self.require_home(capture, False)
        self.checks.append('Owned list absent; expected other list rows preserved.')


def _profile(scenario, value):
    require(isinstance(value, dict), 'A complete expected setup profile is required for this scenario.')
    profile = dict(value)
    require(profile.get('applicationLabel') == ('Contacts' if scenario == 'contacts' else 'Reminders'),
            'The preparation profile targets the wrong application.')
    screen = profile.get('expectedScreen')
    require(isinstance(screen, list) and len(screen) == 2
            and all(type(size) in (int, float) and math.isfinite(size) and size > 0 for size in screen),
            'The expected screen dimensions are required.')
    if scenario == 'contacts':
        fields = {'firstName': 'MCP', 'lastName': 'Contact Benchmark',
                  'organization': 'XcodeBuildMCP Benchmark', 'phoneDigits': '5550104242',
                  'email': 'mcp.contact.benchmark@example.com'}
        require(profile.get('fields') == fields and profile.get('approvedRecord') == 'MCP Contact Benchmark'
                and profile.get('rowLabel') == 'MCP Contact Benchmark, XcodeBuildMCP Benchmark',
                'Only the original benchmark contact can be removed.')
        require(isinstance(profile.get('baselineRows'), list) and bool(profile['baselineRows'])
                and all(isinstance(row, str) and row for row in profile['baselineRows']),
                'Expected complete contact row inventory is required.')
        require(type(profile.get('maximumScrolls')) is int and 0 <= profile['maximumScrolls'] <= 4,
                'Scroll limit must be 0 through 4.')
    else:
        require(sorted(profile.get('ownedReminderRows', [])) == sorted([
            'File report benchmark, Incomplete', 'Buy milk benchmark, Completed', 'Call team benchmark, Completed']),
            'Only the original completed benchmark list can be removed.')
        require(profile.get('ownedListRow') == 'MCP Benchmark List, 1 reminder',
                'Expected owned list row must identify the original benchmark list.')
        require(isinstance(profile.get('baselineListRows'), list) and bool(profile['baselineListRows'])
                and all(isinstance(row, str) and row for row in profile['baselineListRows'])
                and isinstance(profile.get('homeMarker'), str) and profile['homeMarker'],
                'Complete expected list inventory and overview marker are required.')
    return profile


def prepare(scenario, axe_path, udid, output, allow_cleanup=False, profile=None, env=None,
            expected_pid=None):
    """Return ready/blocked plus evidence. Caller owns app launch and termination."""
    from adapters import inspect_tool

    output = Path(output)
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    result = {'status': 'blocked', 'scenario': scenario, 'udid': udid,
              'cleanupOutsideBenchmarkClock': True, 'inputRetries': 0, 'checks': [], 'calls': 0}
    worker = None
    try:
        require(scenario in ('weather', 'contacts', 'reminders'), 'Unknown preparation scenario.')
        require(type(allow_cleanup) is bool, 'Cleanup authorization must be an explicit boolean.')
        require(expected_pid is None or type(expected_pid) is int and expected_pid > 0,
                'Expected launch PID must be a positive integer when supplied.')
        if scenario == 'weather':
            result.update(status='ready', checks=['Weather has no persistent benchmark records to remove.'])
        else:
            checked_profile = _profile(scenario, profile)
            write_json(output / 'profile.json', checked_profile)
            identity = inspect_tool('axe', str(axe_path))
            result['setupTool'] = identity
            args = SimpleNamespace(axe=Path(str(identity['executable'])), udid=udid, out=output,
                                   allow_cleanup=allow_cleanup, timeout=60, env=env, expected_pid=expected_pid)
            worker_type = ContactPreparation if scenario == 'contacts' else ReminderPreparation
            worker = worker_type(args, checked_profile)
            worker.run()
            require(sha256(args.axe) == identity['binarySHA256'], 'Setup CLI changed during preparation.')
            result['status'] = 'ready'
    except Exception as error:
        result['reason'] = str(error)
    finally:
        if worker is not None:
            result.update(calls=len(worker.calls), checks=worker.checks,
                          readinessObservations=worker.readiness_observations)
        write_json(output / 'result.json', result)
    return result

