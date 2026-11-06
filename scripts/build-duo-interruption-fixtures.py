#!/usr/bin/env python3
"""Build the tracked UIKit touch fixture and external-state tool without simulator input.

The caller supplies the native runtime and both Xcode developer directories.
Builds run in order. The output directory must be new. This command does not
install, launch, boot, reset, fold, rotate or send input to any simulator.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORKS = ['FBSimulatorControl', 'FBControlCore', 'FBDeviceControl', 'XCTestBootstrap']
HEADER_FOLDERS = ['', 'AccessibilityPlatformTranslation', 'AXRuntime', 'CoreSimDeviceIO',
                  'CoreSimulator', 'CoreSimulatorUtilities', 'SimulatorKit']
INTERRUPTED_BY = None


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(file):
    check_interruption()
    return hashlib.sha256(file.read_bytes()).hexdigest()


def tree_digest(directory):
    return {str(file.relative_to(directory)): {'symlink': os.readlink(file)} if file.is_symlink()
            else {'sha256': digest(file)} for file in sorted(directory.rglob('*'))
            if file.is_symlink() or file.is_file()}


def metadata(sdk):
    files = {name: digest(sdk / name) for name in ['SDKSettings.json', 'SDKSettings.plist'] if (sdk / name).is_file()}
    require(files, 'SDK settings metadata is missing: ' + str(sdk))
    return dict(directory=str(sdk), settingsSHA256=files)


def check_interruption():
    if INTERRUPTED_BY is not None:
        raise InterruptedError('Build interrupted by ' + INTERRUPTED_BY)


def group_exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def stop_owned_groups(children):
    started = time.monotonic()

    def remaining():
        for process, _ in children:
            process.poll()
        return [(process, record) for process, record in children if group_exists(process.pid)]

    for sig, deadline in [(signal.SIGTERM, started + 1), (signal.SIGKILL, started + 3)]:
        for process, record in remaining():
            try:
                os.killpg(process.pid, sig)
                record['signals'].append(sig.name)
            except ProcessLookupError:
                pass
        while remaining() and time.monotonic() < deadline:
            time.sleep(.025)
    pending = remaining()
    for process, record in children:
        record.update(exitCode=process.poll(), reaped=process.poll() is not None,
                      groupStopped=not group_exists(process.pid))
    return dict(boundSeconds=3, elapsedSeconds=round(time.monotonic() - started, 3),
                allGroupsStopped=not pending, remainingGroups=[process.pid for process, _ in pending])


class Builder:
    def __init__(self, args):
        self.args = args
        self.children = []
        self.cleanup = None
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(('AXE_', 'DYLD_'))}
        self.manifest = dict(schema='axe-duo-interruption-fixture-build/1', status='BUILDING',
                             startedAt=datetime.now(timezone.utc).isoformat(), commands=[], inputs={},
                             nativeInputSent=False, simulatorLifecycleChanged=False,
                             sdkHashScope='SDK settings files; compiler binaries are hashed separately')
        self.save()

    def save(self):
        (self.args.out / 'build-manifest.json').write_text(json.dumps(self.manifest, indent=2, sort_keys=True) + '\n')

    def run(self, name, argv, developer, timeout=90):
        check_interruption()
        record = dict(name=name, argv=[str(value) for value in argv], developerDirectory=str(developer),
                      startedMonotonic=time.monotonic(), signals=[], timedOut=False)
        self.manifest['commands'].append(record)
        self.save()
        stdout = self.args.out / (name + '.stdout')
        with stdout.open('xb') as output, (self.args.out / (name + '.stderr')).open('xb') as error:
            process = subprocess.Popen(record['argv'], stdout=output, stderr=error,
                                       env=self.env | {'DEVELOPER_DIR': str(developer)}, start_new_session=True)
        record.update(pid=process.pid, processGroup=process.pid)
        self.children.append((process, record))
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                check_interruption()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(record['argv'], timeout)
                try:
                    process.wait(timeout=min(.1, remaining))
                except subprocess.TimeoutExpired:
                    pass
            check_interruption()
        except BaseException as error:
            record['timedOut'] = isinstance(error, subprocess.TimeoutExpired)
            self.close()
            raise
        finally:
            record.update(exitCode=process.poll(), reaped=process.poll() is not None,
                          elapsedSeconds=round(time.monotonic() - record['startedMonotonic'], 3))
            self.save()
        require(process.returncode == 0, name + ' failed; inspect its saved stdout/stderr')
        return stdout.read_text().strip()

    def close(self):
        if self.cleanup is None:
            self.cleanup = stop_owned_groups(self.children)
            self.manifest['ownedGroupCleanup'] = self.cleanup
        if INTERRUPTED_BY is not None:
            self.manifest['interruptedBy'] = INTERRUPTED_BY
        if not self.cleanup['allGroupsStopped']:
            self.manifest.update(status='FAILED', cleanupError='Owned process groups did not stop within three seconds')

    def build(self):
        args = self.args
        inputs = self.manifest['inputs']
        inputs['runtime'] = dict(directory=str(args.runtime), files=tree_digest(args.runtime))
        headers = args.idb_checkout / 'PrivateHeaders'
        require(headers.is_dir(), 'PrivateHeaders is missing from the explicit IDB checkout')
        inputs['privateHeaders'] = dict(directory=str(headers), files=tree_digest(headers))
        inputs['driver'] = dict(file=str(Path(__file__).resolve()), sha256=digest(Path(__file__)))
        inputs['hostTools'] = {name: digest(Path('/usr/bin') / name) for name in ['xcrun', 'codesign', 'otool']}
        sources = args.out / 'sources'
        sources.mkdir()
        for name in ['DuoTapWaitProbe.m', 'DuoExternalStateChange.swift']:
            original = ROOT / 'scripts/fixtures' / name
            inputs[name] = dict(file=str(original), sha256=digest(original))
            shutil.copyfile(original, sources / name)
        self.save()
        host, guest = args.host_developer_dir, args.guest_developer_dir
        for name, developer in [('host', host), ('guest', guest)]:
            self.run(name + '-xcode', ['/usr/bin/xcrun', 'xcodebuild', '-version'], developer, 30)
        host_sdk = Path(self.run('host-sdk', ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], host, 30))
        guest_sdk = Path(self.run('guest-sdk', ['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], guest, 30))
        self.manifest['SDKs'] = dict(host=metadata(host_sdk), guest=metadata(guest_sdk))
        # Compiler driver mode depends on argv[0]; retain the names returned by xcrun.
        swift = Path(self.run('find-swift', ['/usr/bin/xcrun', '--find', 'swiftc'], host, 30))
        clang = Path(self.run('find-clang', ['/usr/bin/xcrun', '--find', 'clang'], guest, 30))
        swift_executable = swift.resolve(strict=True)
        clang_executable = clang.resolve(strict=True)
        self.manifest['toolchains'] = dict(
            swift=dict(file=str(swift), resolvedExecutable=str(swift_executable), sha256=digest(swift_executable)),
            clang=dict(file=str(clang), resolvedExecutable=str(clang_executable), sha256=digest(clang_executable)))
        self.run('swift-version', [swift, '--version'], host, 30)
        self.run('clang-version', [clang, '--version'], guest, 30)
        app = args.out / 'DuoTapWaitProbe.app'
        app.mkdir()
        orientations = ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
                        'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
        info = dict(CFBundleExecutable='DuoTapWaitProbe', CFBundleIdentifier='com.camsoft.duo-tap-wait-probe',
                    CFBundleName='DuoTapWaitProbe', CFBundlePackageType='APPL', CFBundleShortVersionString='1.0',
                    CFBundleVersion='1', LSRequiresIPhoneOS=True, MinimumOSVersion='17.0', UIDeviceFamily=[1, 2],
                    UILaunchScreen={}, UISupportedInterfaceOrientations=orientations,
                    UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {
                        'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Default',
                                                                'UISceneDelegateClassName': 'WaitSceneDelegate'}]}})
        info['UISupportedInterfaceOrientations~ipad'] = orientations
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        self.run('fixture', [clang, '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', guest_sdk,
                            '-fobjc-arc', '-fblocks', '-framework', 'UIKit', '-framework', 'Foundation',
                            '-framework', 'CoreGraphics', sources / 'DuoTapWaitProbe.m', '-o', app / 'DuoTapWaitProbe'], guest)
        self.run('fixture-sign', ['/usr/bin/codesign', '--force', '--sign', '-', app], guest, 30)
        self.run('fixture-verify', ['/usr/bin/codesign', '--verify', '--strict', app], guest, 30)
        cache = args.out / 'module-cache'
        cache.mkdir()
        operator = args.out / 'duo-external-state-change'
        self.run('operator', [swift, '-parse-as-library', '-swift-version', '5', '-j', '2', '-sdk', host_sdk,
                             '-module-cache-path', cache, '-F', args.runtime, '-framework', 'FBSimulatorControl',
                             '-framework', 'FBControlCore', '-Xlinker', '-rpath', '-Xlinker', args.runtime,
                             *['-I' + str(headers / folder) for folder in HEADER_FOLDERS],
                             sources / 'DuoExternalStateChange.swift', '-o', operator], host)
        self.run('operator-sign', ['/usr/bin/codesign', '--force', '--sign', '-', operator], host, 30)
        self.run('operator-verify', ['/usr/bin/codesign', '--verify', '--strict', operator], host, 30)
        self.run('operator-linkage', ['/usr/bin/otool', '-L', operator], host, 30)
        require(tree_digest(headers) == inputs['privateHeaders']['files'], 'Private headers changed during the build')
        for name in ['DuoTapWaitProbe.m', 'DuoExternalStateChange.swift']:
            require(digest(Path(inputs[name]['file'])) == digest(sources / name) == inputs[name]['sha256'],
                    'Source changed during the build: ' + name)
        self.manifest.update(status='BUILT_NOT_INSTALLED',
                             outputs={str(file.relative_to(args.out)): digest(file)
                                      for file in [app / 'Info.plist', app / 'DuoTapWaitProbe', operator]})


def terminate(signum, _frame):
    global INTERRUPTED_BY
    if INTERRUPTED_BY is None:
        INTERRUPTED_BY = signal.Signals(signum).name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['runtime', 'host-developer-dir', 'guest-developer-dir', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--idb-checkout', type=Path, default=ROOT / 'idb_checkout',
                        help='IDB checkout containing PrivateHeaders; default: repository idb_checkout.')
    args = parser.parse_args()
    for name in ['runtime', 'host_developer_dir', 'guest_developer_dir', 'idb_checkout']:
        value = getattr(args, name).resolve(strict=True)
        require(value.is_dir(), name + ' must be a directory')
        setattr(args, name, value)
    for file in ['axe'] + [name + '.framework/' + name for name in FRAMEWORKS]:
        require((args.runtime / file).is_file(), 'Runtime input is missing: ' + file)
    args.out = args.out.resolve()
    require(not args.out.is_relative_to(args.runtime)
            and not args.out.is_relative_to(args.idb_checkout / 'PrivateHeaders'), 'Output cannot be inside an input directory')
    args.out.mkdir(parents=True, exist_ok=False)
    builder = Builder(args)
    signal.signal(signal.SIGINT, terminate)
    signal.signal(signal.SIGTERM, terminate)
    try:
        builder.build()
    except BaseException as error:
        builder.manifest.update(status='FAILED', error=repr(error))
    finally:
        builder.close()
        if INTERRUPTED_BY is not None:
            builder.manifest.update(status='FAILED', runtimeUnchanged=None,
                                    runtimeVerificationError='Interrupted; post-cancel runtime hashing was skipped')
        elif 'runtime' in builder.manifest['inputs']:
            try:
                unchanged = tree_digest(args.runtime) == builder.manifest['inputs']['runtime']['files']
                builder.manifest['runtimeUnchanged'] = unchanged
                if not unchanged:
                    builder.manifest.update(status='FAILED', runtimeVerificationError='Original runtime changed during the build')
            except (OSError, RuntimeError) as error:
                builder.manifest.update(status='FAILED', runtimeVerificationError=repr(error))
        builder.manifest['finishedAt'] = datetime.now(timezone.utc).isoformat()
        builder.save()
    print(json.dumps(dict(status=builder.manifest['status'], manifest=str(args.out / 'build-manifest.json'))))
    return 0 if builder.manifest['status'] == 'BUILT_NOT_INSTALLED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
