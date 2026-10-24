#!/usr/bin/env python3
"""Observe and stop an owned public AXe media command; no product hooks or input replay."""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


class BSDInfo(ctypes.Structure):
    # macOS sys/proc_info.h, struct proc_bsdinfo (PROC_PIDTBSDINFO=3).
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid",
        "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "jobc", "tdev", "tpgid")]
    _fields_ += [("nice", ctypes.c_int32), ("startSeconds", ctypes.c_uint64),
                 ("startMicroseconds", ctypes.c_uint64)]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libproc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
libproc.proc_listpids.restype = ctypes.c_int
libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
libproc.proc_pidinfo.restype = ctypes.c_int
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int
libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                       ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
libc.sysctl.restype = ctypes.c_int


def listed(kind, owner):
    # proc_listpids returns bytes. A full buffer is refused, never silently truncated.
    values = (ctypes.c_int * 8192)()
    count = libproc.proc_listpids(kind, owner, values, ctypes.sizeof(values))
    if count < 0 or count >= ctypes.sizeof(values) or count % ctypes.sizeof(ctypes.c_int):
        raise RuntimeError("Cannot obtain a complete owned process inventory")
    return {pid for pid in values[:count // ctypes.sizeof(ctypes.c_int)] if pid > 0}


def info(pid):
    value = BSDInfo()
    result = libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(value), ctypes.sizeof(value))
    if result == 0 and ctypes.get_errno() in (errno.ESRCH, errno.ENOENT):
        return None
    if result != ctypes.sizeof(value):
        raise RuntimeError("Cannot read process identity for PID " + str(pid))
    return {"pid": value.pid, "ppid": value.ppid, "pgid": value.pgid, "status": value.status,
            "startSeconds": value.startSeconds, "startMicroseconds": value.startMicroseconds}


def identity(row):
    return (row["pid"], row["startSeconds"], row["startMicroseconds"])


def describe(row):
    path = ctypes.create_string_buffer(4096)
    count = libproc.proc_pidpath(row["pid"], path, len(path))
    if count <= 0:
        return None  # A transient child may exit between inventory and executable read.
    mib = (ctypes.c_int * 3)(1, 49, row["pid"])  # CTL_KERN, KERN_PROCARGS2, pid.
    data = ctypes.create_string_buffer(262144)
    size = ctypes.c_size_t(len(data))
    if libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
        if ctypes.get_errno() in (errno.ESRCH, errno.ENOENT):
            return None
        raise RuntimeError("Cannot read argv for an owned process")
    raw = data.raw[:size.value]
    argc = int.from_bytes(raw[:4], sys.byteorder, signed=True)
    if argc < 1 or argc > 8192:
        raise RuntimeError("Invalid owned process argv")
    offset = raw.index(b"\0", 4) + 1
    while offset < len(raw) and raw[offset] == 0:
        offset += 1
    args = raw[offset:].split(b"\0")[:argc]
    after = info(row["pid"])
    if after is None or identity(after) != identity(row):
        return None
    return dict(row, executable=os.fsdecode(path.value), arguments=[os.fsdecode(arg) for arg in args])


def write_json(destination, value):
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(destination)


def verify_deferred(args, command):
    """Read-only final check. It never launches, signals or stops a product process."""
    started = time.monotonic()
    failures, owned, remaining = [], {}, []
    records, boot, baseline_guest = [], None, set()
    dedicated_groups = set()
    helper = str(Path(command[0]).resolve().parent / "cadisplay-context")
    udid = command[command.index("--udid") + 1]
    try:
        files = sorted(args.verify_deferred_directory.glob("*-ownership.json"))
        if not files:
            raise RuntimeError("No deferred command ownership receipts")
        for file in files:
            if file.is_symlink() or not file.is_file():
                raise RuntimeError("A deferred receipt is not a regular file")
            record = json.loads(file.read_text())
            argv = record.get("command", [])
            if (record.get("schemaVersion") != 1 or not record.get("groupCheckDeferred")
                    or not record.get("directCLIReaped") or record.get("failures") or record.get("forcedCleanup")
                    or not argv or Path(argv[0]).resolve() != Path(command[0]).resolve()
                    or "--udid" not in argv or argv[argv.index("--udid") + 1].lower() != udid.lower()):
                raise RuntimeError("A deferred command receipt is incomplete or belongs to another target")
            current_boot = tuple(record["guestBootIdentity"])
            if boot is None:
                boot = current_boot
            elif boot != current_boot:
                raise RuntimeError("Deferred commands used different simulator boots")
            records.append(record)
            dedicated_groups.add(record["cliPID"])
            for row in record["owned"]:
                owned.setdefault(identity(row), row)
                if row.get("ownership") != "selected-boot-guest-helper" and row["pgid"] == row["pid"]:
                    dedicated_groups.add(row["pgid"])
        # Only identities present before every command are borrowed from outside this case.
        baseline_guest = set.intersection(*(set(tuple(row) for row in record["baselineGuestIdentities"]) for record in records))
        empty_since = None
        while True:
            current_boot = info(boot[0])
            if current_boot is None or identity(current_boot) != boot:
                raise RuntimeError("The selected boot changed during final process verification")
            # Check only dedicated CLI/descendant groups, never a shared launchd_sim guest group.
            # This also detects an orphan that remains after its recorded parent exits.
            for group in list(dedicated_groups):
                for pid in listed(2, group):
                    member = info(pid)
                    if member is not None and member["pgid"] == group:
                        owned.setdefault(identity(member), dict(member, ownership="recorded-case-group-member"))
            for key in list(owned):
                current = info(key[0])
                if current is None or identity(current) != key:
                    continue
                if owned[key].get("ownership") != "selected-boot-guest-helper" and current["pgid"] == current["pid"]:
                    dedicated_groups.add(current["pgid"])
                for pid in listed(6, current["pid"]):
                    child = info(pid)
                    detailed = describe(child) if child is not None else None
                    if detailed is not None:
                        owned.setdefault(identity(detailed), detailed)
            for pid in listed(6, boot[0]):
                current = info(pid)
                if current is None:
                    continue
                executable = ctypes.create_string_buffer(4096)
                count = libproc.proc_pidpath(pid, executable, len(executable))
                if count <= 0 or os.fsdecode(executable.value) != helper:
                    continue
                detailed = describe(current)
                if detailed is not None and identity(detailed) not in baseline_guest:
                    owned.setdefault(identity(detailed), dict(detailed, ownership="selected-boot-guest-helper"))
            remaining = []
            for key in list(owned):
                current = info(key[0])
                if current is not None and identity(current) == key:
                    remaining.append(current)
            if remaining:
                empty_since = None
            elif empty_since is None:
                empty_since = time.monotonic()
            if empty_since is not None and time.monotonic() - empty_since >= 0.25:
                break
            if time.monotonic() - started >= args.timeout:
                raise RuntimeError("Deferred owned processes did not exit within the final test limit")
            time.sleep(0.02)
    except BaseException as error:
        failures.append(str(error))
    receipt = {"schemaVersion": 1, "phase": "finalDeferredGroupVerification", "command": command,
               "cliPID": records[0]["cliPID"] if records else None,
               "cliExitCode": 0 if not failures else 70,
               "directCLIReaped": bool(records) and all(record["directCLIReaped"] for record in records),
               "owned": list(owned.values()), "matchedSignalChild": None, "forcedCleanup": [],
               "remaining": remaining, "failures": failures,
               "completeOwnedGroupAbsent": bool(records) and not failures and not remaining,
               "newSelectedBootGuestHelpersAbsent": bool(records) and not failures and not remaining,
               "guestBootIdentity": boot, "baselineGuestIdentities": sorted(baseline_guest),
               "commandReceipts": len(records), "dedicatedProcessGroups": sorted(dedicated_groups),
               "elapsedSeconds": time.monotonic() - started,
               "scope": "final read-only PID/start identity check for deferred case commands and their descendants"}
    write_json(args.receipt, receipt)
    return 70 if failures else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--phase", choices=["capture-int", "context-term"])
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--defer-group-check", action="store_true")
    parser.add_argument("--verify-deferred-directory", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not Path(command[0]).is_absolute() or args.receipt.exists():
        parser.error("An absolute CLI command and a new receipt are required")
    if (args.defer_group_check and args.verify_deferred_directory) or (args.phase and (args.defer_group_check or args.verify_deferred_directory)):
        parser.error("Deferred UI command checks cannot use media signal phases")
    if (args.defer_group_check or args.verify_deferred_directory) and not 0 < args.timeout <= 120:
        parser.error("Deferred UI checks require a positive bounded test timeout no greater than120seconds")
    if args.verify_deferred_directory is not None:
        return verify_deferred(args, command)
    child = None
    owned = {}
    requested = []
    matched = None
    failures = []
    forced = []
    started = time.monotonic()
    cli_exit = None
    root_identity = None
    empty_since = None
    helper = str(Path(command[0]).resolve().parent / "cadisplay-context")
    boot_identity = None
    baseline_guest = set()
    udid = command[command.index("--udid") + 1]

    def selected_boot():
        # Read the actual warm target, including tests that intentionally supply a wrong expected boot.
        matches = []
        for pid in listed(1, 0):
            path = ctypes.create_string_buffer(4096)
            count = libproc.proc_pidpath(pid, path, len(path))
            if count <= 0 or Path(os.fsdecode(path.value)).name != "launchd_sim":
                continue
            row = info(pid)
            detailed = describe(row) if row is not None else None
            if detailed is not None and any(udid.lower() in arg.lower() for arg in detailed["arguments"]):
                matches.append(identity(detailed))
        if len(matches) != 1:
            raise RuntimeError("The media observer requires one existing warm simulator boot")
        return matches[0]

    def guest_helpers():
        if boot_identity is None:
            return []
        current_boot = info(boot_identity[0])
        if current_boot is None or identity(current_boot) != boot_identity:
            raise RuntimeError("The selected boot changed during owned media observation")
        result = []
        for pid in listed(6, boot_identity[0]):
            row = info(pid)
            if row is None:
                continue
            path = ctypes.create_string_buffer(4096)
            count = libproc.proc_pidpath(pid, path, len(path))
            if count > 0 and os.fsdecode(path.value) == helper:
                detailed = describe(row)
                if detailed is not None:
                    result.append(dict(detailed, ownership="selected-boot-guest-helper"))
        return result

    def receive(number, _frame):
        requested.append(number)

    signal.signal(signal.SIGINT, receive)
    signal.signal(signal.SIGTERM, receive)

    def sample():
        pids = listed(2, child.pid)  # All members of this dedicated product process group.
        parents = {child.pid} | {key[0] for key in owned}
        for parent in parents:
            current = info(parent)
            expected = root_identity if parent == child.pid else next(
                (key for key in owned if key[0] == parent), None)
            if current is not None and identity(current) == expected:
                pids.update(listed(6, parent))  # Also record children that change process group.
        guest_rows = [row for row in guest_helpers() if identity(row) not in baseline_guest]
        for row in guest_rows:
            owned.setdefault(identity(row), row)
        rows = list(guest_rows)
        for pid in pids:
            row = info(pid)
            if row is None:
                continue
            key = identity(row)
            if key not in owned:
                owned[key] = describe(row) or row
            rows.append(row)
        for key in list(owned):
            current = info(key[0])
            if current is not None and identity(current) == key and all(identity(row) != key for row in rows):
                rows.append(current)
        return rows

    def live_root():
        row = info(child.pid)
        return row is not None and identity(row) == root_identity

    try:
        boot_identity = selected_boot()
        baseline_guest = {identity(row) for row in guest_helpers()}
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=sys.stdout.buffer,
                                 stderr=sys.stderr.buffer, start_new_session=True)
        first = info(child.pid)
        if first is None or first["pgid"] != child.pid:
            raise RuntimeError("The media CLI has no unique owned process group")
        root_identity = identity(first)
        owned[root_identity] = describe(first) or first
        while True:
            rows = sample()
            cli_exit = child.poll()  # Reap the direct CLI; descendants remain owned by product code.
            while requested:
                number = requested.pop(0)
                if cli_exit is None and live_root():
                    os.kill(child.pid, number)
            if args.phase and matched is None:
                for row in list(owned.values()):
                    current = info(row["pid"])
                    if current is None or identity(current) != identity(row):
                        continue
                    if "executable" not in row:
                        detailed = describe(current)
                        if detailed is None:
                            continue
                        row.update(detailed)
                    argv = row.get("arguments", [])
                    capture = Path(row.get("executable", "")).name == "simctl" and (
                        len(argv) >= 6 and argv[1] == "io" and argv[2] == udid and argv[3] == "screenshot"
                        and argv[4].startswith("--display=") and argv[5].endswith("/capture.png"))
                    context = Path(row.get("executable", "")).name == "devicectl" and (
                        len(argv) >= 10 and argv[1:5] == ["device", "info", "displays", "--device"]
                        and argv[5].lower() == udid.lower() and "--json-output" in argv
                        and argv[-1].endswith("/response.json"))
                    if (args.phase == "capture-int" and capture) or (args.phase == "context-term" and context):
                        if cli_exit is not None or not live_root():
                            raise RuntimeError("CLI exited before the target child could be signalled")
                        number = signal.SIGINT if args.phase == "capture-int" else signal.SIGTERM
                        matched = dict(row, signal=number, observedSeconds=time.monotonic() - started)
                        write_json(args.receipt.with_name(args.receipt.stem + "-signal.json"), matched)
                        os.kill(child.pid, number)
                        break
            if cli_exit is not None and args.defer_group_check:
                break  # The caller consumes the CLI reply now; group ownership is verified once after the case.
            if cli_exit is not None:
                remaining = [row for row in rows if identity(row) != root_identity]
                if remaining:
                    empty_since = None
                elif empty_since is None:
                    empty_since = time.monotonic()
                stable = 5 if args.phase else 0.25
                if empty_since is not None and time.monotonic() - empty_since >= stable:
                    break
            if args.phase and matched is None and cli_exit is not None:
                raise RuntimeError("The real target child was not observed; no signal test was performed")
            if time.monotonic() - started >= args.timeout:
                raise RuntimeError("Owned media command or descendant cleanup exceeded its test limit")
            time.sleep(0.003 if args.phase and matched is None else 0.02)
    except BaseException as error:
        failures.append(str(error))
    finally:
        if child is not None and args.defer_group_check and child.poll() is not None:
            cli_exit = child.poll()
            remaining = sample()  # Retain live broker identities. Do not signal a group that later UI commands can reuse.
        elif child is not None:
            # A failed check cannot strand a known owned child. Forced cleanup is always a test failure.
            if child.poll() is None:
                failures.append("The test had to stop its owned CLI")
            for number in (signal.SIGTERM, signal.SIGKILL):
                rows = sample()
                alive = [row for row in rows if identity(row) in owned]
                if not alive:
                    break
                for row in alive:
                    current = info(row["pid"])
                    if current is not None and identity(current) == identity(row):
                        os.kill(row["pid"], number)
                        forced.append({"pid": row["pid"], "signal": number})
                stop = time.monotonic() + 2
                while time.monotonic() < stop and sample():
                    child.poll()
                    time.sleep(0.02)
            cli_exit = child.poll()
            remaining = sample()
            if cli_exit is None or remaining:
                failures.append("Owned process exit is not confirmed")
        else:
            remaining = []
        receipt = {"schemaVersion": 1, "command": command, "cliPID": child.pid if child else None,
                   "cliExitCode": cli_exit, "directCLIReaped": child is not None and cli_exit is not None,
                   "owned": list(owned.values()), "matchedSignalChild": matched,
                   "forcedCleanup": forced, "remaining": remaining, "failures": failures,
                   "completeOwnedGroupAbsent": child is not None and not remaining,
                   "newSelectedBootGuestHelpersAbsent": not [row for row in remaining if row.get("ppid") == (boot_identity[0] if boot_identity else -1)],
                   "guestBootIdentity": boot_identity, "baselineGuestIdentities": sorted(baseline_guest),
                   "groupCheckDeferred": args.defer_group_check,
                   "elapsedSeconds": time.monotonic() - started,
                   "scope": "dedicated CLI group, observed descendants, and new exact-runtime CAD helpers of the selected boot; PID/start identities"}
        write_json(args.receipt, receipt)
    if failures or forced:
        return 70
    return cli_exit if cli_exit is not None and cli_exit >= 0 else 70


if __name__ == "__main__":
    sys.exit(main())
