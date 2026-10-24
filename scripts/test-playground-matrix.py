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
           'PlaygroundAgentTests.swift', 'PlaygroundKeyboardTests.swift', 'PlaygroundDuoTests.swift',
           'PlaygroundDuoSupport.swift', 'PlaygroundDuoCoreTests.swift', 'PlaygroundInterruptionTests.swift',
           'PlaygroundTouchMonitorSupport.swift']
HEADER_FOLDERS = ['', 'AccessibilityPlatformTranslation', 'AXRuntime', 'CoreSimDeviceIO',
                  'CoreSimulator', 'CoreSimulatorUtilities', 'SimulatorKit']


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def payload_manifest(folder):
    files, links = {}, {}
    for file in sorted(folder.rglob('*')):
        name = str(file.relative_to(folder))
        if file.is_symlink():
            links[name] = os.readlink(file)
        elif file.is_file():
            files[name] = digest(file)
    return dict(files=files, links=links)


def selected_suites(kind, suite):
    duo = ['PlaygroundDuoCoreTests', 'PlaygroundDuoTests', 'PlaygroundDuoInterruptionTests']
    if suite == 'core':
        return ['PlaygroundCoreTests']
    if suite == 'agent':
        return ['PlaygroundAgentTests']
    if suite == 'duo':
        return duo
    if kind == 'iphone':
        return ['PlaygroundCoreTests', 'PlaygroundKeyboardTests', 'PlaygroundAgentTests']
    return duo + ['PlaygroundAgentTests']


class ResourceSamples:
    def __init__(self, probe, output):
        self.probe, self.output = probe, output
        self.previous, self.measured_at = {}, None
        self.started = self.next_sample = time.monotonic()
        self.count, self.last = 0, None

    def sample(self, force=False):
        if not force and time.monotonic() < self.next_sample:
            return
        try:
            result = subprocess.run([str(self.probe)], capture_output=True, text=True, timeout=5, check=True)
            payload = json.loads(result.stdout)
            rows = payload['rows']
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            raise RuntimeError('Resource sampling failed: ' + str(error)) from error
        measured = time.monotonic()
        if payload.get('source') != 'publicLibproc' or not rows:
            raise RuntimeError('The resource probe returned no public process counters')
        interval = measured - self.measured_at if self.measured_at is not None else 0
        for row in rows:
            before = self.previous.get(row['pid'])
            row['cpuPercent'] = round(max(0, row['cpuTimeNs'] - before['cpuTimeNs']) / 1e9 / interval * 100, 1) \
                if before and before['start'] == row['start'] and interval > 0 else 0
        selected = [row for row in rows if row['name'] in ('Codex', 'ChatGPT', 'launchd_sim')
                    or any(name in row['name'] for name in ('DeviceHub', 'SimulatorTramp', 'CoreSimulator', 'simdiskimaged'))]
        self.last = dict(elapsedSeconds=round(measured - self.started, 2), source='publicLibproc',
                         processes=selected, largestProcesses=sorted(rows, key=lambda row: row['footprintBytes'], reverse=True)[:5],
                         highestCPUProcesses=sorted(rows, key=lambda row: row['cpuPercent'], reverse=True)[:5])
        with (self.output / 'resources.jsonl').open('a') as stream:
            stream.write(json.dumps(self.last) + '\n')
        self.previous, self.measured_at = {row['pid']: row for row in rows}, measured
        self.next_sample, self.count = measured + 15, self.count + 1


def read_suite_result(xml, suite, expected):
    result = dict(name=suite, status='FAIL', expected=expected, executed=0, skipped=0, failed=0, checks=[])
    tree = ET.parse(xml.with_name(xml.stem + '-swift-testing.xml')).getroot()
    tests = list(tree.iter('testcase'))
    skipped = [item for item in tests if item.find('skipped') is not None]
    failures = [item for item in tests if item.find('failure') is not None or item.find('error') is not None]
    result.update(executed=len(tests) - len(skipped), skipped=len(skipped), failed=len(failures),
                  checks=[dict(name=item.get('name'), status='SKIP' if item in skipped else 'FAIL' if item in failures else 'PASS')
                          for item in tests])
    if result['executed'] == expected and not skipped and not failures:
        result['status'] = 'PASS'
    else:
        result['error'] = f'Expected {expected} executed checks; got {result["executed"]}, skipped {len(skipped)}, failed {len(failures)}'
    return result


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
        self.resources = None

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
                if self.resources is not None:
                    self.resources.sample()
                if time.monotonic() >= deadline:
                    self.stop_groups([(process, entry)])
                    raise subprocess.TimeoutExpired(entry['argv'], timeout)
                time.sleep(.05)
            self.check_interruption()
            # The leader can exit while its child or grandchild still owns this group.
            self.stop_groups([(process, entry)])
            if self.resources is not None:
                self.resources.sample()
            output = (self.output / (name + '.log')).read_text(errors='replace')
            if process.returncode:
                raise RuntimeError(f'{name} failed ({process.returncode}):\n{output[-6000:]}')
            return output
        except BaseException:
            if self.interrupted_by is None:
                self.stop_groups([(process, entry)])
            raise
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
    parser.add_argument('--suite', choices=['core', 'agent', 'duo', 'all'], default='all')
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
    host_override = env.get('AXE_TEST_HOST_DEVELOPER_DIR')
    idb_override = env.get('AXE_TEST_IDB_SOURCE')
    for key in list(env):
        if key.startswith(('AXE_', 'DYLD_')):
            del env[key]
    env.update(AXE_ENV_FILE='/dev/null', AXE_E2E='1', AXE_LANDSCAPE_E2E='0', AXE_BIN_PATH=str(args.axe))
    if args.developer_dir:
        env['DEVELOPER_DIR'] = args.developer_dir
    report = dict(status='RUNNING', requestedSuite=args.suite, requestedDevices=args.only or 'both',
                  cli=str(args.axe), cliSHA256=digest(args.axe), payloadBefore=payload_manifest(args.axe.parent),
                  sourceHashes={}, runnerSHA256=digest(Path(__file__)), commands=[], devices=[], startedAt=time.time())
    owned = None
    commands = OwnedCommands(args.output, env, report)
    run, save = commands.run, commands.save
    signal.signal(signal.SIGINT, commands.interrupt)
    signal.signal(signal.SIGTERM, commands.interrupt)

    try:
        counts_file = ROOT / 'scripts/playground-suite-counts.json'
        expected_counts = json.loads(counts_file.read_text())
        if not expected_counts or any(type(value) is not int or value <= 0 for value in expected_counts.values()):
            raise RuntimeError('Playground suite counts must be positive integers')
        report['suiteExpectedCounts'] = expected_counts
        report['sourceHashes']['scripts/playground-suite-counts.json'] = digest(counts_file)
        requested = [('iphone', str(args.iphone).upper()), ('duo', str(args.duo).upper())]
        if args.only:
            requested = [(kind, identifier) for kind, identifier in requested if kind == args.only]
        report['plannedSuites'] = [dict(kind=kind, name=suite, expected=expected_counts[suite])
                                   for kind, _ in requested for suite in selected_suites(kind, args.suite)]
        developer = run('selected-xcode', ['xcode-select', '-p']).strip()
        developer = env.get('DEVELOPER_DIR', developer)
        env['DEVELOPER_DIR'] = developer
        report['developerDirectory'] = developer
        report['xcode'] = run('xcode-version', ['xcodebuild', '-version']).strip()
        probe_source = ROOT / 'scripts/duo-resource-probe.c'
        probe = args.output / 'resource-probe'
        report['sourceHashes']['scripts/duo-resource-probe.c'] = digest(probe_source)
        run('build-resource-probe', ['xcrun', 'clang', '-O2', str(probe_source), '-o', str(probe)])
        commands.resources = ResourceSamples(probe, args.output)
        commands.resources.sample(force=True)
        inventory = json.loads(run('device-inventory', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
        devices = {row['udid']: row | {'runtime': runtime}
                   for runtime, rows in inventory['devices'].items() for row in rows}
        for kind, identifier in requested:
            device = devices.get(identifier)
            if not device or not device.get('isAvailable'):
                raise RuntimeError(f'{kind} simulator is unavailable: {identifier}')
            device_type = device.get('deviceTypeIdentifier', '')
            if 'iPhone' not in device_type or ('iPhone-Duo' in device_type) != (kind == 'duo'):
                raise RuntimeError(f'{kind} has wrong device type: {device_type}')
            if device['state'] not in ('Shutdown', 'Booted'):
                raise RuntimeError(f'{kind} is not ready to boot or use: {device["state"]}')
        if any(kind == 'duo' for kind, _ in requested) and args.suite in ('all', 'duo'):
            host = Path(host_override or developer).resolve(strict=True)
            idb = Path(idb_override or ROOT / 'idb_checkout').resolve(strict=True)
            headers = idb / 'PrivateHeaders'
            if not host.is_dir() or not headers.is_dir():
                raise RuntimeError('The selected host Xcode or IDB PrivateHeaders directory is missing')
            frameworks = args.axe.parent / 'Frameworks'
            for name in ['FBSimulatorControl', 'FBControlCore', 'FBDeviceControl', 'XCTestBootstrap']:
                if not (frameworks / (name + '.framework') / name).is_file():
                    raise RuntimeError('The supplied payload is missing Frameworks/' + name + '.framework/' + name)
            operator_source = ROOT / 'scripts/fixtures/DuoExternalStateChange.swift'
            report['sourceHashes']['scripts/fixtures/DuoExternalStateChange.swift'] = digest(operator_source)
            report['externalStateTool'] = dict(hostDeveloperDirectory=str(host), idbSource=str(idb), frameworks=str(frameworks),
                                                hostOverride=host_override, idbOverride=idb_override,
                                                privateHeaders=payload_manifest(headers))
            source = args.output / 'DuoExternalStateChange.swift'
            shutil.copyfile(operator_source, source)
            host_env = {'DEVELOPER_DIR': str(host)}
            report['externalStateTool']['xcode'] = run('operator-xcode', ['xcrun', 'xcodebuild', '-version'], extra_env=host_env).strip()
            sdk = run('operator-sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], extra_env=host_env).strip()
            operator = args.output / 'duo-external-state-change'
            run('build-state-operator', ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-j', '1',
                                        '-sdk', sdk, '-module-cache-path', str(args.output / 'operator-module-cache'),
                                        '-F', str(frameworks), '-framework', 'FBSimulatorControl', '-framework', 'FBControlCore',
                                        '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                                        *['-I' + str(headers / folder) for folder in HEADER_FOLDERS], str(source), '-o', str(operator)],
                timeout=180, extra_env=host_env)
            run('sign-state-operator', ['codesign', '--force', '--sign', '-', str(operator)])
            run('verify-state-operator', ['codesign', '--verify', '--strict', str(operator)])
            if digest(source) != report['sourceHashes']['scripts/fixtures/DuoExternalStateChange.swift'] \
                    or payload_manifest(headers) != report['externalStateTool']['privateHeaders']:
                raise RuntimeError('The external state tool source or headers changed during its build')
            report['externalStateTool'].update(binary=str(operator), binarySHA256=digest(operator),
                                                sourceSHA256=digest(source), macOSSDK=sdk)
            env['AXE_DUO_STATE_CHANGE_PATH'] = str(operator)
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
                               '-jobs', '1', 'CODE_SIGNING_ALLOWED=NO'], timeout=600)
        app = derived / 'Build/Products/Debug-iphonesimulator/AxePlayground.app'
        if not app.is_dir():
            raise RuntimeError('Built playground app is missing')
        report['playgroundPayload'] = payload_manifest(app)
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
        run('build-checks', ['xcrun', 'swift', 'build', '--package-path', str(package), '--build-tests', '--jobs', '1'], timeout=300)
        hub = Path(developer).parent / 'Applications/DeviceHub.app'
        if hub.is_dir():
            run('start-device-hub', ['open', '-g', str(hub)])
        for kind, identifier in requested:
            device = devices[identifier]
            case = dict(kind=kind, udid=identifier, runtime=device['runtime'], name=device['name'], initialState=device['state'], status='RUNNING')
            report['devices'].append(case)
            owned = identifier if device['state'] == 'Shutdown' else None
            try:
                if device['state'] == 'Shutdown':
                    run(kind + '-boot', ['xcrun', 'simctl', 'boot', identifier])
                run(kind + '-boot-ready', ['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=180)
                run(kind + '-install', ['xcrun', 'simctl', 'install', identifier, str(app)])
                suites = selected_suites(kind, args.suite)
                case['suites'] = []
                for suite in suites:
                    expected = expected_counts[suite]
                    xml = args.output / (kind + '-' + suite + '.xml')
                    failure = None
                    try:
                        artifacts = args.output / (kind + '-' + suite + '-artifacts')
                        artifacts.mkdir()
                        suite_env = {'SIMULATOR_UDID': identifier, 'AXE_DUO_E2E': '1' if suite.startswith('PlaygroundDuo') else '0',
                                     'AXE_E2E_ARTIFACT_DIR': str(artifacts)}
                        run(kind + '-' + suite, ['xcrun', 'swift', 'test', '--package-path', str(package), '--skip-build',
                                                '--no-parallel', '--filter', suite, '--xunit-output', str(xml)],
                            timeout=max(900, expected * 60), extra_env=suite_env)
                    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, ET.ParseError) as error:
                        failure = str(error)
                    try:
                        result = read_suite_result(xml, suite, expected)
                    except (OSError, ValueError, ET.ParseError) as error:
                        result = dict(name=suite, status='FAIL', expected=expected, executed=0, skipped=0, failed=0,
                                      checks=[], error='No complete Swift Testing result: ' + str(error))
                    if failure:
                        result.update(status='FAIL', commandError=failure)
                    result['artifactDirectory'] = str(args.output / (kind + '-' + suite + '-artifacts'))
                    case['suites'].append(result)
                    save()
                    if result['status'] != 'PASS':
                        print(f'{kind}/{suite}: ' + result.get('error', failure or 'Failed'), file=sys.stderr)
                case['status'] = 'PASS' if all(item['status'] == 'PASS' for item in case['suites']) else 'FAIL'
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, ET.ParseError) as error:
                case.update(status='FAIL', error=str(error))
                print(str(error), file=sys.stderr)
            finally:
                if commands.interrupted_by is None:
                    final_inventory = json.loads(run(kind + '-final-state', ['xcrun', 'simctl', 'list', 'devices', '-j']))
                    final_rows = [row for rows in final_inventory['devices'].values() for row in rows
                                  if row['udid'] == identifier]
                    case['leftBooted'] = len(final_rows) == 1 and final_rows[0]['state'] == 'Booted'
                    if not case['leftBooted']:
                        case.update(status='FAIL', finalStateError='The simulator did not remain booted')
                    owned = None
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
        try:
            suites = [suite for device in report['devices'] for suite in device.get('suites', [])]
            report['checks'] = {key: sum(suite.get(key, 0) for suite in suites)
                                for key in ('executed', 'skipped', 'failed')}
            report['checks']['expected'] = sum(suite['expected'] for suite in report.get('plannedSuites', []))
            report['checks']['notExecuted'] = report['checks']['expected'] - report['checks']['executed']
            report['payloadUnchanged'] = payload_manifest(args.axe.parent) == report['payloadBefore']
            if not report['payloadUnchanged']:
                report.update(status='FAIL', payloadError='The supplied AXe payload changed during the run')
            if commands.resources is not None:
                commands.resources.sample(force=True)
                report['resources'] = dict(sampleCount=commands.resources.count, intervalSeconds=15,
                                           log='resources.jsonl', last=commands.resources.last)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            report.update(status='FAIL', evidenceError=str(error))
        report['elapsedSeconds'] = round(time.time() - report['startedAt'], 2)
        save()
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
