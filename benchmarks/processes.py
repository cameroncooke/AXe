"""Track benchmark descendants across detached process groups and reparenting.

Ownership comes from observed ancestry, never process names. Each signal uses
a fresh PID/start-time match. Unobserved fork-and-exit races cannot be recovered
from a later process table; sample while the launcher remains alive.
"""
from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
import signal
import subprocess
import time


@dataclass(frozen=True)
class ProcessRecord:
    pid: int
    ppid: int
    pgid: int
    started: str
    state: str
    name: str

    @property
    def identity(self):
        return self.pid, self.started

    @property
    def running(self):
        return not self.state.startswith('Z')

    def receipt(self):
        return {'pid': self.pid, 'ppid': self.ppid, 'pgid': self.pgid,
                'started': self.started, 'state': self.state, 'name': self.name}


def process_snapshot():
    result = subprocess.run(
        ['/bin/ps', '-axo', 'pid=,ppid=,pgid=,lstart=,stat=,comm='],
        capture_output=True, text=True, timeout=2, check=True,
        env={**os.environ, 'LC_ALL': 'C'})
    records = {}
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        cells = line.split(None, 9)
        if len(cells) != 10:
            raise ValueError('Incomplete process identity in ps output')
        record = ProcessRecord(int(cells[0]), int(cells[1]), int(cells[2]),
                               ' '.join(cells[3:8]), cells[8],
                               os.path.basename(cells[9]))
        records[record.pid] = record
    return records


def validate_model_run_root(model_run_root):
    root = Path(model_run_root).resolve() if model_run_root else None
    if root and not re.fullmatch(r'axe-bench-[a-z]+-[a-z]+-[0-9a-f]{12}', root.name):
        raise ValueError('Expected the unique generated benchmark suite directory')
    return root


class ProcessTracker:
    def __init__(self, child_pid, model_run_root=None):
        if type(child_pid) is not int or child_pid <= 1 or child_pid == os.getpid():
            raise ValueError('Expected a child process PID')
        self.seed_pid = child_pid
        self.model_run_root = validate_model_run_root(model_run_root)
        self.owned = {}
        self.initialized = False

    def sample(self):
        current = process_snapshot()
        if not self.initialized:
            seed = current.get(self.seed_pid)
            if seed is None and self.model_run_root is None:
                raise RuntimeError('Benchmark launcher exited before its identity was observed')
            if seed is not None:
                self.owned[seed.pid] = seed
            self.initialized = True
        # Refresh only matching identities. Retain missing/reparented descendants
        # so they remain owned when an ancestor has exited.
        live = {pid for pid, known in self.owned.items()
                if pid in current and current[pid].identity == known.identity}
        for pid in live:
            self.owned[pid] = current[pid]
        # The harness detaches Claude. Its unique generated MCP configuration
        # binds a missed/reparented launcher to this suite without a name-wide kill.
        if self.model_run_root:
            candidates = [row for row in current.values() if row.name == 'claude' and row.running and row.pid not in live]
            if candidates:
                response = subprocess.run(['/bin/ps', '-p', ','.join(str(row.pid) for row in candidates),
                                           '-o', 'pid=,command='], capture_output=True, text=True,
                                          timeout=2, check=False)
                if response.returncode not in (0, 1):
                    raise RuntimeError('Cannot inspect detached benchmark model identity')
                allowed = {row.pid for row in candidates}
                for line in response.stdout.splitlines():
                    parts = line.strip().split(None, 1)
                    if len(parts) != 2 or not parts[0].isdigit() or int(parts[0]) not in allowed:
                        continue
                    match = re.search(r'(?:^|\s)--mcp-config(?:=|\s+)[\"\x27]?([^\s\"\x27]+)', parts[1])
                    if not match:
                        continue
                    config = Path(match.group(1))
                    if not config.is_absolute() or config.name != 'mcp-config.json':
                        continue
                    try:
                        config.resolve().relative_to(self.model_run_root)
                    except ValueError:
                        continue
                    pid = int(parts[0])
                    self.owned[pid] = current[pid]
                    live.add(pid)
        changed = True
        while changed:
            changed = False
            for pid, record in current.items():
                if pid not in live and record.ppid in live:
                    self.owned[pid] = record
                    live.add(pid)
                    changed = True
        return {pid: current[pid] for pid in live if current[pid].running}

    def cleanup(self, term_seconds=3.0, kill_seconds=2.0):
        """Stop observed owned processes, including new groups; return proof.

        Never signal a process group: an unknown group member is not proof of
        ownership. Descendants get individual signals after fresh identity checks.
        Any unavailable final snapshot makes cleanup incomplete.
        """
        if not 0 <= term_seconds <= 10 or not 0 <= kill_seconds <= 10:
            raise ValueError('Cleanup waits must be between zero and ten seconds')
        receipt = {'complete': False, 'remaining': [], 'signals': [], 'errors': [],
                   'trackedCount': len(self.owned), 'initiallyRunning': [],
                   'identityScope': 'PID and ps lstart; observed ancestry or exact unique suite MCP config'}
        try:
            active = self.sample()
            receipt['initiallyRunning'] = [row.receipt() for row in active.values()]
            for sig, duration in ((signal.SIGTERM, term_seconds), (signal.SIGKILL, kill_seconds)):
                sent = set()
                deadline = time.monotonic() + duration
                while active:
                    # Signal children before their observed parents. A new snapshot
                    # before every signal also discovers recently created children.
                    def depth(row):
                        seen = set()
                        while row.ppid in active and row.ppid not in seen:
                            seen.add(row.ppid)
                            row = active[row.ppid]
                        return len(seen)
                    ordered = sorted(active.values(), key=depth, reverse=True)
                    for known in ordered:
                        if time.monotonic() >= deadline:
                            break
                        fresh = self.sample().get(known.pid)
                        if fresh is None or fresh.identity != known.identity or fresh.identity in sent:
                            continue
                        try:
                            os.kill(fresh.pid, sig)
                            receipt['signals'].append({'pid': fresh.pid, 'started': fresh.started,
                                                       'signal': sig.name})
                        except ProcessLookupError:
                            pass
                        sent.add(fresh.identity)
                    active = self.sample()
                    if not active or time.monotonic() >= deadline:
                        break
                    time.sleep(.05)
                if not active:
                    break
            active = self.sample()
            receipt['remaining'] = [row.receipt() for row in active.values()]
            receipt['complete'] = not active
        except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as error:
            receipt['errors'].append(type(error).__name__ + ': ' + str(error))
        receipt['trackedCount'] = len(self.owned)
        return receipt
