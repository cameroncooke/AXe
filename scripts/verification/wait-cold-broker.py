#!/usr/bin/env python3
"""Wait for existing raw helpers to close naturally. Never start, stop or connect to a helper."""
import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import tempfile
import time
import uuid


def digest(file):
    result = hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda: stream.read(256 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def fnv(value):
    result = 14695981039346656037
    for byte in str(value).encode():
        result = ((result ^ byte) * 1099511628211) & 0xffffffffffffffff
    return format(result, 'x')


def locked(file):
    try:
        descriptor = os.open(file, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except FileNotFoundError:
        return False
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError('An input lock is not a private regular file owned by this user.')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            return False
    finally:
        os.close(descriptor)


p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--cli', type=Path, required=True)
p.add_argument('--udid', required=True)
p.add_argument('--developer-directory', type=Path, required=True)
p.add_argument('--wait-seconds', type=float, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
if not math.isfinite(a.wait_seconds) or not 0 < a.wait_seconds <= 75:
    p.error('The caller must supply the remaining positive allowance, at most 75 seconds.')
udid = str(uuid.UUID(a.udid)).upper()
if udid != a.udid:
    p.error('Use the canonical uppercase simulator UUID used by the test.')
started = time.monotonic()
deadline = started + a.wait_seconds
cli = a.cli.resolve(strict=True)
developer = a.developer_directory.resolve(strict=True)
def hid_socket_path(filename):
    # Mirror HIDBroker.endpointLocation: the per-user temporary directory (with Foundation's
    # /private prefix removed) while the socket fits sun_path, otherwise /tmp (issue #83).
    preferred = str(Path(tempfile.gettempdir()).resolve())
    if preferred.startswith(('/private/var/', '/private/tmp/')):
        preferred = preferred[len('/private'):]
    for base in (preferred, '/tmp'):
        path = Path(base) / ('axe-hid-' + str(os.getuid())) / filename
        if len(str(path).encode()) < 104:
            return path
    raise RuntimeError('No AXe input socket path fits sun_path for ' + filename)


root = hid_socket_path(fnv(udid) + '-' + fnv(str(developer)) + '-v3.sock').parent
if os.path.lexists(root):
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('The input namespace is not a private directory owned by this user.')

def endpoint(directory, version):
    return hid_socket_path(fnv(udid) + '-' + fnv(directory) + '-v' + str(version) + '.sock')

raw3 = endpoint(developer, 3)
raw2 = endpoint(developer, 2)
common = endpoint('/candidate-device-input', 3)
quarantine = Path(str(common) + '.quarantine.json')
observations = Path(str(a.out) + '.observations.jsonl')
value = dict(schemaVersion=1, status='PREPARATION_FAILED', cliPath=str(cli), cliSHA256=digest(cli),
             udid=udid, developerDirectory=str(developer), protocolVersion=3, tempRoot=str(root),
             endpoint=str(raw3), lifetimeLock=str(raw3) + '.lifetime.lock',
             inputSent=False, brokerConnected=False, processStopped=False,
             waitAllowanceSeconds=a.wait_seconds, error=None)
error = None
try:
    with observations.open('x') as log:
        samples = 0
        while True:
            if os.path.lexists(quarantine):
                raise RuntimeError('Input quarantine is present; no input or recovery was attempted.')
            row = dict(elapsedSeconds=time.monotonic()-started,
                       brokerAlive=locked(Path(str(raw3) + '.lifetime.lock')),
                       legacyBrokerAlive=locked(Path(str(raw2) + '.lifetime.lock')),
                       commonLeaseHeld=locked(Path(str(common) + '.lifetime.lock')))
            log.write(json.dumps(row, sort_keys=True) + '\n')
            log.flush()
            samples += 1
            value.update(row, observations=samples, checkedUnixSeconds=time.time(),
                         socketExists=raw3.exists(), lifetimeLockExists=Path(value['lifetimeLock']).exists())
            if not row['brokerAlive'] and not row['legacyBrokerAlive'] and not row['commonLeaseHeld']:
                if time.monotonic() >= deadline:
                    raise RuntimeError('The shared setup deadline expired before a clear observation.')
                value['status'] = 'COLD_BROKER_ABSENT'
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0 or samples >= 302:
                raise TimeoutError('Existing input ownership did not clear within the remaining setup allowance.')
            time.sleep(min(0.25, remaining))
except (OSError, RuntimeError, TimeoutError) as failure:
    error = type(failure).__name__ + ': ' + str(failure)
    value.update(status='PREPARATION_FAILED', error=error, checkedUnixSeconds=time.time())
value['elapsedSeconds'] = time.monotonic() - started
with a.out.open('x') as output:
    output.write(json.dumps(value, indent=2, sort_keys=True) + '\n')
print(json.dumps(value, sort_keys=True))
raise SystemExit(0 if value['status'] == 'COLD_BROKER_ABSENT' else 1)
