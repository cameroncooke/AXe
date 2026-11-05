"""Record a warm simulator and the exact benchmark inputs. No guest writes."""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


def command(argv, env=None, timeout=30):
    result = subprocess.run([str(x) for x in argv], env=env, capture_output=True,
                            text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{argv[0]} exited {result.returncode}: {result.stderr[-1500:]}')
    return result.stdout.strip()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def tree_digest(root, prefixes=None):
    root = Path(root)
    excluded = {'.git', '.build', 'DerivedData', 'build', 'build_products',
                'node_modules', 'xcuserdata', '__pycache__', '.DS_Store'}
    files = []
    for prefix in prefixes or ['.']:
        source = root / prefix
        candidates = [source] if source.is_file() else source.rglob('*')
        for file in candidates:
            relative = file.relative_to(root)
            if any(part in excluded for part in relative.parts):
                continue
            if file.is_symlink():
                raise ValueError(f'Benchmark source must not contain symlinks: {file}')
            if not file.is_file():
                continue
            files.append((relative.as_posix(), digest(file)))
    if not files:
        raise ValueError(f'No benchmark source files at {root}')
    return hashlib.sha256(json.dumps(sorted(set(files)), separators=(',', ':')).encode()).hexdigest()


def lock_state():
    result = subprocess.run(['/usr/sbin/ioreg', '-n', 'Root', '-d', '1', '-a'],
                            capture_output=True, timeout=5, check=True)
    data = plistlib.loads(result.stdout)
    value = data.get('IOConsoleLocked') if isinstance(data, dict) else None
    if type(value) is not bool:
        raise RuntimeError('Cannot read the public console lock flag')
    return value


def host_environment(udid, developer_dir, env):
    devices = json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json'], env))
    matches = [(runtime, device) for runtime, group in devices['devices'].items()
               for device in group if device['udid'] == udid]
    if len(matches) != 1 or matches[0][1]['state'] != 'Booted':
        raise RuntimeError('Select one existing booted simulator; this suite does not create or boot devices')
    runtime_id, device = matches[0]
    runtimes = json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', 'runtimes', '--json'], env))
    runtime = next(item for item in runtimes['runtimes'] if item['identifier'] == runtime_id)
    if lock_state():
        raise RuntimeError('The Mac is locked; unlock it before a live benchmark')
    with tempfile.TemporaryDirectory(prefix='axe-benchmark-display-') as folder:
        output = Path(folder) / 'display.json'
        command(['/usr/bin/xcrun', 'devicectl', 'device', 'info', 'displays', '--device',
                 udid, '--timeout', '10', '--json-output', output], env)
        displays = json.loads(output.read_text())['result']['displays']
    active = [row for row in displays if row.get('active') is True]
    if (not active and len(displays) == 1 and 'active' not in displays[0]
            and displays[0].get('primary') is True
            and displays[0].get('backlightState') == 'activeOn'
            and 'integrated' in displays[0].get('type', {})):
        active = displays
    if len(active) != 1:
        raise RuntimeError('Cannot identify one active simulator display')
    panel = active[0]
    width, height = panel['nativeSize']
    rotation = panel['currentOrientation']
    if rotation in ('rot90', 'rot270'):
        width, height = height, width
    elif rotation not in ('rot0', 'rot180'):
        raise RuntimeError('Unrecognized display orientation')
    scale = panel['pointScale']
    return {'udid': udid, 'deviceName': device['name'], 'deviceType': device['deviceTypeIdentifier'],
            'runtimeVersion': runtime['version'] + ' (' + runtime['buildversion'] + ')',
            'runtimeIdentifier': runtime_id, 'screenWidth': width / scale, 'screenHeight': height / scale,
            'rotation': rotation, 'displayId': panel['displayId'], 'scale': scale,
            'hostOS': command(['/usr/bin/sw_vers', '-productVersion']),
            'hostBuild': command(['/usr/bin/sw_vers', '-buildVersion']),
            'hostArchitecture': command(['/usr/bin/uname', '-m']),
            'hostModel': command(['/usr/sbin/sysctl', '-n', 'hw.model']),
            'xcodeVersion': command([str(Path(developer_dir) / 'usr/bin/xcodebuild'), '-version'], env),
            'developerDir': developer_dir, 'claudeVersion': command(['claude', '--version'], env),
            'nodeVersion': command(['node', '--version'], env)}


def app_identity(scenario, config, env):
    if scenario == 'weather':
        project = Path(config['weatherProject']).resolve(strict=True)
        return {'sourceSHA256': tree_digest(project.parent), 'project': str(project),
                'directory': str(project.parent), 'scheme': 'Weather', 'bundleId': 'com.sentry.weather.Weather'}
    bundle = {'contacts': 'com.apple.MobileAddressBook', 'reminders': 'com.apple.reminders'}[scenario]
    app = Path(command(['/usr/bin/xcrun', 'simctl', 'get_app_container', config['simulator'], bundle, 'app'], env))
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = app / info['CFBundleExecutable']
    source = {'info': digest(app / 'Info.plist'), 'binary': digest(executable)}
    return {'sourceSHA256': hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest(),
            'directory': str(Path(config['xcodebuildmcp']).resolve()), 'bundleId': bundle,
            'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion')}
