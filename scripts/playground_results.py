#!/usr/bin/env python3
"""Count completed Swift Testing case instances from the version-0 event stream."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET


class EventFormatError(ValueError):
    pass


class EventResults:
    def __init__(self):
        self.definitions = {}
        self.started = set()
        self.finished_functions = set()
        self.suites = []
        self.function = None
        self.active_case = None
        self.ordinals = {}
        self.checks = []
        self.issues = []
        self.skipped = []
        self.cancelled = []
        self.run_started = self.run_ended = False
        self.last_instant = None
        self.started_cases = 0

    def require(self, condition, message):
        if not condition:
            raise EventFormatError(message)

    def record(self, record, line):
        self.require(isinstance(record, dict), f'Line {line}: expected an object')
        self.require(type(record.get('version')) is int and record['version'] == 0,
                     f'Line {line}: unsupported event stream version')
        kind, payload = record.get('kind'), record.get('payload')
        if kind not in ('test', 'event'):
            return  # The public schema permits new record kinds.
        self.require(isinstance(payload, dict), f'Line {line}: missing payload')
        if kind == 'test':
            identifier = payload.get('id')
            self.require(isinstance(identifier, str) and identifier, f'Line {line}: missing test ID')
            self.require(identifier not in self.definitions, f'Line {line}: duplicate test definition')
            self.require(payload.get('kind') in ('suite', 'function'), f'Line {line}: unknown test kind')
            if payload['kind'] == 'function':
                self.require(type(payload.get('isParameterized')) is bool, f'Line {line}: missing parameterized flag')
            self.definitions[identifier] = payload
            return
        self.event(payload, line)

    def begin_case(self, identifier, messages):
        self.require(self.active_case is None, 'Overlapping case instances in a serial run')
        ordinal = self.ordinals.get(identifier, 0) + 1
        self.ordinals[identifier] = ordinal
        definition = self.definitions[identifier]
        self.active_case = dict(testID=identifier, ordinal=ordinal,
            name=definition.get('displayName', definition['name']), status='PASS',
            messages=[message.get('text') for message in messages if isinstance(message, dict)])
        self.started_cases += 1

    def end_case(self, identifier):
        self.require(self.active_case is not None and self.active_case['testID'] == identifier,
                     'Case end has no matching serial start')
        self.checks.append(self.active_case)
        self.active_case = None

    def event(self, event, line):
        kind = event.get('kind')
        instant = event.get('instant', {}).get('absolute')
        self.require(type(instant) in (int, float) and math.isfinite(instant), f'Line {line}: invalid event time')
        self.require(self.last_instant is None or instant >= self.last_instant, f'Line {line}: event time moved backwards')
        self.last_instant = instant
        if kind == 'runStarted':
            self.require(not self.run_started and not self.run_ended, 'More than one test run')
            self.run_started = True
            return
        self.require(self.run_started and not self.run_ended, f'Line {line}: event outside the test run')
        if kind == 'runEnded':
            self.require(not self.suites and self.function is None and self.active_case is None,
                         'Run ended before every started suite, function and case ended')
            self.run_ended = True
            return
        if kind == 'issueRecorded':
            self.issues.append(dict(testID=event.get('testID'), issue=event.get('issue'), messages=event.get('messages')))
            if self.active_case is not None:
                self.active_case['status'] = 'FAIL'
            return
        if kind in ('testSkipped', 'testCancelled', 'testCaseCancelled'):
            target = self.skipped if kind == 'testSkipped' else self.cancelled
            target.append(dict(kind=kind, testID=event.get('testID')))
            if self.active_case is not None:
                self.active_case['status'] = 'FAIL'
            return
        if kind == 'valueAttached':
            return
        self.require(kind in ('testStarted', 'testEnded', 'testCaseStarted', 'testCaseEnded'),
                     f'Line {line}: unsupported lifecycle event {kind}')
        identifier = event.get('testID')
        self.require(identifier in self.definitions, f'Line {line}: event has no declared test')
        definition = self.definitions[identifier]
        is_suite = definition['kind'] == 'suite'
        if kind == 'testStarted':
            self.require(identifier not in self.started, 'A test declaration started more than once')
            self.require(self.function is None, 'Overlapping function declarations in a serial run')
            self.started.add(identifier)
            if is_suite:
                self.suites.append(identifier)
            else:
                self.function = identifier
                if not definition['isParameterized']:
                    self.begin_case(identifier, event.get('messages', []))
            return
        if kind == 'testEnded':
            if is_suite:
                self.require(self.function is None and self.suites and self.suites[-1] == identifier,
                             'Suite end has no matching nested start')
                self.suites.pop()
            else:
                self.require(self.function == identifier, 'Function end has no matching start')
                if definition['isParameterized']:
                    self.require(self.active_case is None and self.ordinals.get(identifier, 0) > 0,
                                 'Parameterized function ended with missing case results')
                else:
                    self.end_case(identifier)
                self.finished_functions.add(identifier)
                self.function = None
            return
        self.require(not is_suite and definition['isParameterized'] and self.function == identifier,
                     'Parameterized case event is outside its function')
        if kind == 'testCaseStarted':
            self.begin_case(identifier, event.get('messages', []))
        else:
            self.end_case(identifier)


def read_suite_result(xml, events, suite, expected):
    result = dict(name=suite, status='FAIL', expected=expected, executed=0, started=0,
                  skipped=0, failed=0, cancelled=0, issues=0, checks=[], errors=[],
                  executionSource='SwiftTestingEventStreamV0')
    state = EventResults()
    try:
        data = Path(events).read_bytes()
        result['eventStreamSHA256'] = hashlib.sha256(data).hexdigest()
        state.require(data.endswith(b'\n'), 'Event stream has no complete final record delimiter')
        for number, line in enumerate(data.splitlines(), 1):
            state.require(bool(line), f'Line {number}: empty event record')
            state.record(json.loads(line), number)
        state.require(state.run_started and state.run_ended, 'No complete test run')
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        result['errors'].append('Event stream: ' + str(error))
    result.update(executed=len(state.checks), started=state.started_cases, skipped=len(state.skipped),
                  failed=sum(check['status'] == 'FAIL' for check in state.checks), cancelled=len(state.cancelled),
                  issues=len(state.issues), checks=state.checks, completedRun=state.run_ended,
                  completedDeclarations=len(state.finished_functions))
    result['casesWithoutCompletedResults'] = max(0, expected - result['executed'])
    result['issueRecords'] = state.issues
    result['skipRecords'] = state.skipped
    result['cancellationRecords'] = state.cancelled
    try:
        data = Path(xml).read_bytes()
        result['xmlSHA256'] = hashlib.sha256(data).hexdigest()
        tests = list(ET.fromstring(data).iter('testcase'))
        xml_skips = sum(test.find('skipped') is not None for test in tests)
        xml_failures = sum(test.find('failure') is not None or test.find('error') is not None for test in tests)
        result['xml'] = dict(declarations=len(tests), skipped=xml_skips, failed=xml_failures)
        if len(tests) != len(state.finished_functions) or xml_skips or xml_failures:
            result['errors'].append('XML declaration count differs from completed event functions, or XML has failures/skips')
    except (OSError, ValueError, ET.ParseError) as error:
        result['errors'].append('XML: ' + str(error))
    if result['executed'] != expected:
        result['errors'].append(f'Expected {expected} completed case instances; got {result["executed"]}')
    if state.issues or state.skipped or state.cancelled:
        result['errors'].append('The event stream contains issues, skips or cancellation')
    if not result['errors'] and result['executed'] == expected:
        result['status'] = 'PASS'
    else:
        result['error'] = '; '.join(result['errors'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xml', type=Path, required=True)
    parser.add_argument('--events', type=Path, required=True)
    parser.add_argument('--suite', required=True)
    parser.add_argument('--expected', type=int, required=True)
    args = parser.parse_args()
    result = read_suite_result(args.xml, args.events, args.suite, args.expected)
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
