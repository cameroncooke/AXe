"""Sample CPU/RSS and lock state while one benchmark process group runs."""
from __future__ import annotations

import json
import signal
import subprocess
import time
from pathlib import Path

from environment import lock_state
from processes import ProcessTracker, validate_model_run_root


def resource_sample():
    output = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,%cpu=,rss=,comm='],
                            capture_output=True, text=True, timeout=5, check=True).stdout
    rows = []
    names = ('axe', 'flowdeck', 'rocketsim', 'devicehub', 'simulator', 'coresimulator',
             'claude', 'codex', 'node', 'xcodebuild', 'swift-frontend')
    for line in output.splitlines():
        parts = line.split(None, 4)
        if len(parts) != 5:
            continue
        name = Path(parts[4]).name
        if any(word in name.lower() for word in names):
            rows.append({'pid': int(parts[0]), 'name': name, 'cpuPercent': float(parts[2]),
                         'rssBytes': int(parts[3]) * 1024})
    return {'elapsedAt': time.monotonic(), 'processes': rows,
            'locked': lock_state(), 'memoryMeasure': 'RSS; not physical footprint'}


def run_monitored(argv, cwd, env, output, timeout=1000, max_process_gib=20, model_run_root=None):
    model_run_root = validate_model_run_root(model_run_root)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    samples, peak, stop = 0, 0, None
    failed_samples, consecutive_failures = 0, 0
    ownership_failures = 0
    (output / 'command.json').write_text(json.dumps(argv, indent=2) + '\n')
    with (output / 'stdout').open('wb') as stdout, (output / 'stderr').open('wb') as stderr:
        child = subprocess.Popen(['/usr/bin/caffeinate', '-di', *argv], cwd=cwd, env=env,
                                 stdout=stdout, stderr=stderr, start_new_session=True)
        tracker = ProcessTracker(child.pid, model_run_root=model_run_root)
        next_sample, next_ownership = 0, 0
        try:
            while child.poll() is None:
                now = time.monotonic()
                if now >= next_ownership:
                    try:
                        owned = tracker.sample()
                        ownership_failures = 0
                        ownership = {'processes': [row.receipt() for row in owned.values()]}
                    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as error:
                        ownership_failures += 1
                        ownership = {'sampleError': type(error).__name__ + ': ' + str(error)}
                        if ownership_failures >= 3:
                            stop = 'processOwnershipUnavailable'
                    with (output / 'owned-processes.jsonl').open('a') as stream:
                        stream.write(json.dumps({'elapsedSeconds': now - started, **ownership}) + '\n')
                    next_ownership = now + 1
                if now >= next_sample:
                    try:
                        sample = resource_sample()
                        consecutive_failures = 0
                    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as error:
                        failed_samples += 1
                        consecutive_failures += 1
                        sample = {'processes': [], 'locked': None,
                                  'sampleError': type(error).__name__ + ': ' + str(error)}
                        if consecutive_failures >= 3:
                            stop = 'resourceMonitoringUnavailable'
                    sample['elapsedSeconds'] = now - started
                    sample.pop('elapsedAt', None)
                    with (output / 'resources.jsonl').open('a') as stream:
                        stream.write(json.dumps(sample) + '\n')
                    samples += 1
                    largest = max((p['rssBytes'] for p in sample['processes']), default=0)
                    peak = max(peak, largest)
                    if sample['locked']:
                        stop = 'hostLocked'
                    elif largest > max_process_gib * 1024 ** 3:
                        stop = 'processMemoryLimit'
                    next_sample = now + 5
                if now - started > timeout:
                    stop = 'benchmarkTimeout'
                if stop:
                    break
                time.sleep(.25)
        except BaseException as error:
            stop = type(error).__name__ + ': ' + str(error)
        finally:
            previous_signals = {sig: signal.signal(sig, signal.SIG_IGN)
                                for sig in (signal.SIGINT, signal.SIGTERM)}
            try:
                if child.poll() is not None:
                    time.sleep(.25)  # Permit the keep-awake helper to exit normally.
                try:
                    cleanup = tracker.cleanup()
                except Exception as error:
                    cleanup = {'complete': False, 'initiallyRunning': [], 'remaining': [],
                               'errors': [type(error).__name__ + ': ' + str(error)]}
                if not cleanup['complete']:
                    stop = 'ownedProcessCleanupIncomplete'
                elif stop is None and any(row.get('name') == 'claude'
                                          for row in cleanup['initiallyRunning']):
                    stop = 'ownedModelAtExit'
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    cleanup['complete'] = False
                    stop = 'ownedProcessCleanupIncomplete'
            finally:
                for sig, handler in previous_signals.items():
                    signal.signal(sig, handler)
    result = {'exitCode': child.returncode, 'stopReason': stop, 'samples': samples,
              'elapsedSeconds': time.monotonic() - started, 'peakProcessRSSBytes': peak,
              'failedSamples': failed_samples,
              'cleanup': cleanup,
              'intervalSeconds': 5, 'maxProcessGiB': max_process_gib,
              'memoryMeasure': 'RSS; not physical footprint'}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
