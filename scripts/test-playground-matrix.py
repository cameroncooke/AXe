#!/usr/bin/env python3
"""Build the tracked playground and run the same CLI checks on iPhone and Duo."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
SOURCES = ['TestUtilities.swift', 'TestUIState.swift', 'PlaygroundCoreTests.swift',
           'PlaygroundAgentTests.swift', 'PlaygroundDuoTests.swift']


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


class RunInterrupted(Exception):
    pass


def group_exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


class OwnedCommands:
    def __init__(self, output, environment, report):
        self.output, self.environment, self.report = output, environment, report
        self.children = []
        self.interrupted_by = self.interrupted_at = self.shutdown_child = None

    def save(self):
        (self.output / 'result.json').write_text(json.dumps(self.report, indent=2) + '\n')

    def interrupt(self, number, _frame):
        if self.interrupted_by is None:
            self.interrupted_by = signal.Signals(number).name
            self.interrupted_at = time.monotonic()

    def check_interruption(self):
        if self.interrupted_by is not None:
            raise RunInterrupted('Interrupted by ' + self.interrupted_by)

    def start(self, name, command, extra_env=None, cleanup_only=False):
        if not cleanup_only:
            self.check_interruption()
        entry = dict(name=name, argv=[str(value) for value in command], startedAt=time.time(),
                     startedMonotonic=time.monotonic(), signals=[], cleanupOnly=cleanup_only)
        self.report['commands'].append(entry)
        self.save()
        with (self.output / (name + '.log')).open('xb') as log:
            if not cleanup_only:
                self.check_interruption()
            process = subprocess.Popen(entry['argv'], cwd=ROOT, env=self.environment | (extra_env or {}),
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        entry.update(pid=process.pid, processGroup=process.pid)
        self.children.append((process, entry))
        self.save()
        return process, entry

    def remaining(self, children):
        for process, _ in children:
            process.poll()
        return [(process, entry) for process, entry in children if group_exists(process.pid)]

    def stop_groups(self, children):
        started = time.monotonic()
        for sig, deadline in [(signal.SIGTERM, started + 1), (signal.SIGKILL, started + 3)]:
            self.check_interruption()
            for process, entry in self.remaining(children):
                try:
                    os.killpg(process.pid, sig)
                    entry['signals'].append(sig.name)
                except ProcessLookupError:
                    pass
            while self.remaining(children) and time.monotonic() < deadline:
                self.check_interruption()
                time.sleep(.025)
        pending = self.remaining(children)
        for process, entry in children:
            entry.update(exitCode=process.poll(), reaped=process.poll() is not None,
                         groupStopped=not group_exists(process.pid))
        if pending:
            raise RuntimeError('Owned process groups did not stop within three seconds')

    def run(self, name, command, timeout=120, extra_env=None, shutdown=False):
        print(name, flush=True)
        process, entry = self.start(name, command, extra_env)
        if shutdown:
            self.shutdown_child = process
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                self.check_interruption()
                if time.monotonic() >= deadline:
                    self.stop_groups([(process, entry)])
                    raise subprocess.TimeoutExpired(entry['argv'], timeout)
                time.sleep(.05)
            self.check_interruption()
            # The leader can exit while its child or grandchild still owns this group.
            self.stop_groups([(process, entry)])
            output = (self.output / (name + '.log')).read_text(errors='replace')
            if process.returncode:
                raise RuntimeError(f'{name} failed ({process.returncode}):\n{output[-6000:]}')
            return output
        finally:
            entry.update(exitCode=process.poll(), elapsedSeconds=round(time.monotonic() - entry['startedMonotonic'], 2))
            self.save()

    def cancel_cleanup(self, shutdown_command):
        # Only owned-device shutdown can start after cancellation. It runs alongside group cleanup.
        for process, entry in self.remaining(self.children):
            if process is self.shutdown_child:
                continue
            try:
                os.killpg(process.pid, signal.SIGINT)
                entry['signals'].append('SIGINT')
            except ProcessLookupError:
                pass
        if shutdown_command is not None and self.shutdown_child is None:
            try:
                self.shutdown_child, _ = self.start('cancel-owned-shutdown', shutdown_command, cleanup_only=True)
            except OSError as error:
                self.report['cancelShutdownError'] = repr(error)
        kill_at, finish_at = self.interrupted_at + 3.3, self.interrupted_at + 4.4
        while self.remaining(self.children) and time.monotonic() < finish_at:
            if time.monotonic() >= kill_at:
                for process, entry in self.remaining(self.children):
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                        if 'SIGKILL' not in entry['signals']:
                            entry['signals'].append('SIGKILL')
                    except ProcessLookupError:
                        pass
            time.sleep(.025)
        pending = self.remaining(self.children)
        for process, entry in self.children:
            entry.update(exitCode=process.poll(), reaped=process.poll() is not None,
                         groupStopped=not group_exists(process.pid))
        self.report['cancelCleanup'] = dict(boundSeconds=4.4,
            elapsedSinceSignal=round(time.monotonic() - self.interrupted_at, 3),
            allGroupsStopped=not pending, remainingGroups=[process.pid for process, _ in pending],
            shutdownExitCode=self.shutdown_child.poll() if self.shutdown_child else None,
            shutdownStateReadback='Not queried after cancellation; inspect shutdown exit code')
        self.report.update(status='INTERRUPTED', interruptedBy=self.interrupted_by)
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--axe', type=Path, required=True, help='Built AXe CLI with its runtime frameworks.')
    parser.add_argument('--iphone', type=uuid.UUID, required=True, help='Dedicated ordinary iPhone simulator UUID.')
    parser.add_argument('--duo', type=uuid.UUID, required=True, help='Dedicated Duo simulator UUID.')
    parser.add_argument('--only', choices=['iphone', 'duo'], help='Run one device while fixing a failure.')
    parser.add_argument('--suite', choices=['core', 'agent', 'duo', 'all'], default='core')
    parser.add_argument('--developer-dir', default=os.environ.get('DEVELOPER_DIR'))
    parser.add_argument('--output', type=Path, required=True, help='New result directory; existing results are never replaced.')
    args = parser.parse_args()
    if args.suite == 'duo' and args.only != 'duo':
        parser.error('--suite duo requires --only duo')
    args.axe = args.axe.resolve(strict=True)
    if not os.access(args.axe, os.X_OK):
        parser.error('--axe must be executable')
    if args.iphone == args.duo:
        parser.error('iPhone and Duo must be different devices')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(('AXE_', 'DYLD_')):
            del env[key]
    env.update(AXE_ENV_FILE='/dev/null', AXE_E2E='1', AXE_LANDSCAPE_E2E='0', AXE_BIN_PATH=str(args.axe))
    if args.developer_dir:
        env['DEVELOPER_DIR'] = args.developer_dir
    report = dict(status='RUNNING', cli=str(args.axe), cliSHA256=digest(args.axe),
                  sourceHashes={}, runnerSHA256=digest(Path(__file__)), commands=[], devices=[], startedAt=time.time())
    owned = None
    commands = OwnedCommands(args.output, env, report)
    run, save = commands.run, commands.save
    signal.signal(signal.SIGINT, commands.interrupt)
    signal.signal(signal.SIGTERM, commands.interrupt)

    try:
        developer = run('selected-xcode', ['xcode-select', '-p']).strip()
        developer = env.get('DEVELOPER_DIR', developer)
        env['DEVELOPER_DIR'] = developer
        report['developerDirectory'] = developer
        report['xcode'] = run('xcode-version', ['xcodebuild', '-version']).strip()
        inventory = json.loads(run('device-inventory', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
        devices = {row['udid']: row | {'runtime': runtime}
                   for runtime, rows in inventory['devices'].items() for row in rows}
        requested = [('iphone', str(args.iphone).upper()), ('duo', str(args.duo).upper())]
        if args.only:
            requested = [(kind, identifier) for kind, identifier in requested if kind == args.only]
        for kind, identifier in requested:
            device = devices.get(identifier)
            if not device or not device.get('isAvailable'):
                raise RuntimeError(f'{kind} simulator is unavailable: {identifier}')
            device_type = device.get('deviceTypeIdentifier', '')
            if 'iPhone' not in device_type or ('iPhone-Duo' in device_type) != (kind == 'duo'):
                raise RuntimeError(f'{kind} has wrong device type: {device_type}')
            if device['state'] != 'Shutdown':
                raise RuntimeError(f'{kind} must be shut down first; this runner uses dedicated test devices')
        xcodegen = shutil.which('xcodegen')
        if not xcodegen:
            raise RuntimeError('XcodeGen is required. Install it, then rerun.')
        generated = args.output / 'project'
        generated.mkdir()
        report['sourceHashes']['AxePlaygroundApp/project.yml'] = digest(ROOT / 'AxePlaygroundApp/project.yml')
        for file in sorted((ROOT / 'AxePlaygroundApp/AxePlayground').rglob('*')):
            if file.is_file():
                report['sourceHashes'][str(file.relative_to(ROOT))] = digest(file)
        run('generate-project', [xcodegen, 'generate', '--spec', str(ROOT / 'AxePlaygroundApp/project.yml'), '--project', str(generated)])
        derived = args.output / 'derived'
        run('build-playground', ['xcodebuild', 'build', '-project', str(generated / 'AxePlayground.xcodeproj'),
                               '-scheme', 'AxePlayground', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                               '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', str(derived),
                               '-jobs', '2', 'CODE_SIGNING_ALLOWED=NO'], timeout=600)
        app = derived / 'Build/Products/Debug-iphonesimulator/AxePlayground.app'
        if not app.is_dir():
            raise RuntimeError('Built playground app is missing')
        package = args.output / 'checks'
        sources = package / 'Tests'
        sources.mkdir(parents=True)
        (package / 'Package.swift').write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "PlaygroundChecks", platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "PlaygroundChecks", path: "Tests")])
''')
        for name in SOURCES:
            file = ROOT / 'Tests' / name
            report['sourceHashes']['Tests/' + name] = digest(file)
            shutil.copyfile(file, sources / name)
        run('build-checks', ['xcrun', 'swift', 'build', '--package-path', str(package), '--build-tests', '--jobs', '2'], timeout=300)
        hub = Path(developer).parent / 'Applications/DeviceHub.app'
        if hub.is_dir():
            run('start-device-hub', ['open', '-g', str(hub)])
        for kind, identifier in requested:
            device = devices[identifier]
            case = dict(kind=kind, udid=identifier, runtime=device['runtime'], name=device['name'], status='RUNNING')
            report['devices'].append(case)
            owned = identifier
            try:
                run(kind + '-boot', ['xcrun', 'simctl', 'boot', identifier])
                run(kind + '-boot-ready', ['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=180)
                run(kind + '-install', ['xcrun', 'simctl', 'install', identifier, str(app)])
                suites = [('PlaygroundCoreTests', 8), ('PlaygroundAgentTests', 4)]
                if kind == 'duo':
                    suites.append(('PlaygroundDuoTests', 5))
                if args.suite != 'all':
                    selected = {'core': 'PlaygroundCoreTests', 'agent': 'PlaygroundAgentTests', 'duo': 'PlaygroundDuoTests'}[args.suite]
                    suites = [item for item in suites if item[0] == selected]
                case['suites'] = []
                for suite, expected in suites:
                    try:
                        xml = args.output / (kind + '-' + suite + '.xml')
                        suite_env = {'SIMULATOR_UDID': identifier, 'AXE_DUO_E2E': '1' if suite == 'PlaygroundDuoTests' else '0'}
                        run(kind + '-' + suite, ['xcrun', 'swift', 'test', '--package-path', str(package), '--skip-build',
                                                '--no-parallel', '--filter', suite, '--xunit-output', str(xml)],
                            timeout=900, extra_env=suite_env)
                        tree = ET.parse(xml.with_name(xml.stem + '-swift-testing.xml')).getroot()
                        tests = list(tree.iter('testcase'))
                        skipped = [item for item in tests if item.find('skipped') is not None]
                        failures = [item for item in tests if item.find('failure') is not None or item.find('error') is not None]
                        if len(tests) != expected or skipped or failures:
                            raise RuntimeError(f'{kind}/{suite}: expected {expected} executed checks; got {len(tests)}, skipped {len(skipped)}, failed {len(failures)}')
                        case['suites'].append(dict(name=suite, status='PASS', executed=len(tests), skipped=0,
                                                  checks=[item.get('name') for item in tests]))
                    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, ET.ParseError) as error:
                        case['suites'].append(dict(name=suite, status='FAIL', error=str(error)))
                        print(str(error), file=sys.stderr)
                case['status'] = 'PASS' if all(item['status'] == 'PASS' for item in case['suites']) else 'FAIL'
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, ET.ParseError) as error:
                case.update(status='FAIL', error=str(error))
                print(str(error), file=sys.stderr)
            finally:
                if commands.interrupted_by is None:
                    run(kind + '-shutdown', ['xcrun', 'simctl', 'shutdown', identifier], timeout=45, shutdown=True)
                    owned = None
                    commands.shutdown_child = None
                    case['shutdown'] = True
                save()
        report['status'] = 'PASS' if all(item['status'] == 'PASS' for item in report['devices']) else 'FAIL'
    except (RunInterrupted, KeyboardInterrupt) as error:
        report.update(status='INTERRUPTED', error=str(error))
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, ET.ParseError) as error:
        report.update(status='FAIL', error=str(error))
        print(str(error), file=sys.stderr)
    finally:
        try:
            if commands.interrupted_by is None:
                if owned:
                    run('cleanup-shutdown', ['xcrun', 'simctl', 'shutdown', owned], timeout=45, shutdown=True)
                commands.stop_groups(commands.children)
                report['allOwnedGroupsStopped'] = not commands.remaining(commands.children)
        except RunInterrupted:
            pass
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            report.update(status='FAIL', cleanupError=str(error))
        finally:
            if commands.interrupted_by is not None:
                commands.cancel_cleanup(['xcrun', 'simctl', 'shutdown', owned] if owned else None)
        report['elapsedSeconds'] = round(time.time() - report['startedAt'], 2)
        save()
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
