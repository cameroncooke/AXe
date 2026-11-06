"""Local setup and stable commands for the versioned benchmark engine."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent
PAYLOAD = ('axe', 'Frameworks', 'AXe_AXe.bundle')
TOOLS = ('axe', 'flowdeck', 'rocketsim')
SCENARIOS = ('weather', 'reminders', 'contacts')
COMPETITORS = ('flowdeck', 'rocketsim')


class CleanupPending(RuntimeError):
    """The owned engine did not exit within its cleanup interval."""


def run_engine(command, env):
    child = subprocess.Popen(command, env=env, start_new_session=True)
    requested = None
    deadline = None

    def request_stop(signum, frame):
        nonlocal requested, deadline
        if requested is not None:
            return
        requested = signum
        deadline = time.monotonic() + 60
        if child.poll() is None:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass

    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        for sig in previous:
            signal.signal(sig, request_stop)
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                print(json.dumps({'phase': 'engine-stop', 'pid': child.pid, 'signal': requested,
                                  'engineExited': False, 'cleanup': 'unconfirmed'}), file=sys.stderr)
                raise CleanupPending('Engine PID ' + str(child.pid)
                                     + ' is still running; no further job or history import started')
            try:
                code = child.wait(timeout=1)
                break
            except subprocess.TimeoutExpired:
                continue
            except KeyboardInterrupt:
                request_stop(signal.SIGINT, None)
        if requested is not None:
            print(json.dumps({'phase': 'engine-stop', 'pid': child.pid, 'signal': requested,
                              'engineExited': True, 'exitCode': code}), file=sys.stderr)
        return subprocess.CompletedProcess(command, 128 + requested if requested is not None else code)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest='command', required=True)
    setup = commands.add_parser('setup', help='Install only local benchmark dependencies')
    setup.add_argument('--python', default=sys.executable,
                       help='Python executable used to create benchmarks/.venv')
    commands.add_parser('test', help='Run the offline benchmark regression tests')
    for name in ('doctor', 'run'):
        command = commands.add_parser(name)
        command.add_argument('--config', default=str(HERE / 'config.local.json'))
        if name == 'run':
            command.add_argument('--tools', nargs='+', choices=TOOLS)
            command.add_argument('--scenarios', nargs='+', choices=SCENARIOS)
            command.add_argument('--rerun-competitors', action='store_true',
                                 help='Run FlowDeck and RocketSim even when history already has their '
                                 'current version for every selected scenario')
            command.add_argument('--repeat', type=int, choices=range(1, 11), default=1)
            command.add_argument('--output', help='New artifact directory; must not exist')
            command.add_argument('--registry', default=str(HERE / 'baselines.json'))
            command.add_argument('--axe', help='Benchmark this AXe executable instead of building the '
                                 'current source; its frameworks must be beside it')
        else:
            command.add_argument('--axe', help='Check this AXe executable instead of the current build')
    for name in ('compare', 'accept'):
        command = commands.add_parser(name)
        command.add_argument('report')
        command.add_argument('--registry', default=str(HERE / 'baselines.json'))
    history = commands.add_parser('history', help='Show saved results or import existing evidence')
    history.add_argument('action', nargs='?', choices=('list', 'import'), default='list')
    history.add_argument('source', nargs='?')
    history.add_argument('--root', default=str(HERE / 'history'))
    history.add_argument('--json', action='store_true')
    return result


def local_environment():
    env = dict(os.environ)
    # Keep setup and execution independent of a caller's Python environment.
    env.pop('PYTHONPATH', None)
    env.pop('PYTHONHOME', None)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    env['TIKTOKEN_CACHE_DIR'] = str(HERE / '.cache' / 'tiktoken')
    return env


def absolute(value):
    return str(Path(value).expanduser().resolve())


def artifact_directory():
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    return HERE / 'artifacts' / (stamp + '-' + uuid.uuid4().hex[:12])


def resolved_config(source, axe=None):
    value = json.loads(Path(source).read_text(encoding='utf-8'))
    if not isinstance(value, dict):
        raise ValueError('Benchmark config must be a JSON object')
    value.setdefault('xcodebuildmcp', str(HERE / 'vendor' / 'xcodebuildmcp'))
    value.setdefault('weatherProject', str(HERE / 'apps' / 'Weather' / 'Weather.xcodeproj'))
    if axe is not None:
        # The measured candidate and common preparation use the same AXe build.
        tools = value.setdefault('tools', {})
        if not isinstance(tools, dict):
            raise ValueError('Benchmark config tools must be a JSON object')
        tools.setdefault('axe', {})['executable'] = str(axe)
        value['setupAxe'] = str(axe)
    return value


def build_current_axe(env, destination):
    """Build the current source, then copy the exact payload this run measures.

    scripts/build.sh rebuilds the frameworks only when Packages/IDBKit changed since their last
    build, as make build does; the CLI is always rebuilt, for this Mac's architecture. The copy
    keeps the measured binary after a later build replaces build_products, and the report records
    its hashes.
    """
    executable_env = dict(env)
    executable_env.setdefault('AXE_BUILD_ARCHS', platform.machine())
    for step, step_env in (('frameworks-if-needed', env), ('executable', executable_env)):
        print(json.dumps({'phase': 'build-axe', 'step': step}), file=sys.stderr, flush=True)
        subprocess.run(['/bin/bash', str(REPOSITORY / 'scripts' / 'build.sh'), step], cwd=str(REPOSITORY),
                       env=step_env, check=True, stdout=sys.stderr)
    destination.mkdir(parents=True, exist_ok=False)
    for name in PAYLOAD:
        source = REPOSITORY / 'build_products' / name
        if source.is_dir():
            shutil.copytree(source, destination / name, symlinks=True)
        else:
            shutil.copy2(source, destination / name)
    axe = destination / 'axe'
    version = subprocess.run([str(axe), '--version'], capture_output=True, text=True, check=True).stdout.strip()
    print(json.dumps({'phase': 'build-axe', 'status': 'ready', 'executable': str(axe), 'version': version}),
          file=sys.stderr, flush=True)
    return axe


def recorded_competitors(config, scenarios, history_root):
    """Competitors whose current version already has a measured run for every selected scenario.

    A competitor changes only when its version changes, so a default run reuses those history
    records instead of measuring the same version again. A tool whose version cannot be read is
    not reused; the engine then reports it as usual.
    """
    from adapters import inspect_tool
    from history import list_history
    runs = list_history(history_root)['runs']
    reused = {}
    for name in COMPETITORS:
        spec = config.get('tools', {}).get(name)
        if not isinstance(spec, dict) or not isinstance(spec.get('executable'), str):
            continue
        try:
            version = inspect_tool(name, spec['executable'], spec.get('app'))['version']
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        matches = {scenario: [row for row in runs
                              if row['scenario'] == scenario and row['tool']['name'] == name
                              and row['tool'].get('version') == version and row['status'] != 'blocked']
                   for scenario in scenarios}
        if all(matches.values()):
            reused[name] = {'version': version,
                            'runs': {scenario: [row['runId'] for row in rows] for scenario, rows in matches.items()}}
    return reused


def explicit_axe(value):
    axe = Path(absolute(value))
    if not axe.is_file() or not os.access(axe, os.X_OK):
        raise ValueError('--axe must be an existing executable: ' + str(axe))
    return axe


def run_configured(command, config, env, artifacts=False, axe=None):
    directory = HERE / 'artifacts' if artifacts else None
    if directory:
        directory.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix='.benchmark-config-', dir=directory))
    remove = True
    try:
        resolved = folder / 'config.json'
        resolved.write_text(json.dumps(resolved_config(config, axe), indent=2) + '\n', encoding='utf-8')
        return run_engine([*command, '--config', str(resolved)], env)
    except CleanupPending:
        remove = False
        print(json.dumps({'phase': 'config-retained', 'config': str(folder / 'config.json')}), file=sys.stderr)
        raise
    finally:
        if remove:
            shutil.rmtree(folder)


def setup_environment(python):
    executable = Path(python).expanduser()
    if not executable.is_absolute() or not executable.is_file():
        raise ValueError('--python must be an existing absolute executable path')
    env = local_environment()
    venv = HERE / '.venv'
    if venv.is_symlink():
        raise ValueError('The local .venv directory must not be a symlink')
    local_python = venv / 'bin' / 'python3'
    if not venv.exists():
        subprocess.run([str(executable), '-m', 'venv', str(venv)], env=env, check=True)
    if not local_python.is_file():
        raise RuntimeError('The local .venv is incomplete; inspect it before setup')
    subprocess.run([str(local_python), '-m', 'pip', 'install', '--require-virtualenv', '--disable-pip-version-check',
                    '-r', str(HERE / 'requirements.txt')], env=env, check=True, stdout=sys.stderr)
    Path(env['TIKTOKEN_CACHE_DIR']).mkdir(parents=True, exist_ok=True)
    subprocess.run([str(local_python), '-c',
                    'import tiktoken; tiktoken.get_encoding("o200k_base")'], env=env, check=True)
    vendor = HERE / 'vendor' / 'xcodebuildmcp'
    npm = shutil.which('npm')
    if not npm:
        raise RuntimeError('Install Node.js with npm, then run setup again')
    if not (vendor / 'package-lock.json').is_file():
        raise RuntimeError('The bundled benchmark package-lock.json is missing')
    subprocess.run([npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund'],
                   cwd=str(vendor), env=env, check=True, stdout=sys.stderr)
    config = HERE / 'config.local.json'
    if not config.exists():
        with config.open('x', encoding='utf-8') as stream:
            stream.write((HERE / 'config.example.json').read_text(encoding='utf-8'))
    print(json.dumps({'status': 'ready', 'python': str(local_python),
                      'config': str(config), 'tokenizerCache': env['TIKTOKEN_CACHE_DIR'],
                      'nextStep': 'Set the simulator and the FlowDeck and RocketSim paths in config.local.json; run doctor.'}))
    return 0


def dispatch(args):
    if args.command == 'setup':
        return setup_environment(args.python)
    local_python = HERE / '.venv' / 'bin' / 'python3'
    if not local_python.is_file():
        raise RuntimeError('Run ./benchmarks/run setup first; local benchmark dependencies are missing')
    env = local_environment()
    if args.command == 'test':
        return subprocess.run([str(local_python), '-m', 'unittest', 'discover',
                               '-s', str(HERE), '-p', 'test_*.py'], env=env).returncode
    if args.command == 'history':
        if (args.action == 'import') != (args.source is not None):
            raise ValueError('history import requires SOURCE; history list takes no source')
        command = [str(local_python), str(HERE / 'history.py'), args.action,
                   *([absolute(args.source)] if args.source else []), '--root', absolute(args.root)]
        if args.json:
            command.append('--json')
        return subprocess.run(command, env=env).returncode
    command = [str(local_python), str(HERE / 'benchmark.py'), args.command]
    if args.command in ('compare', 'accept'):
        report = absolute(args.report)
        if args.command == 'accept':
            archive = subprocess.run([str(local_python), str(HERE / 'history.py'), 'import', report,
                                      '--root', str(HERE / 'history'), '--json'],
                                     env=env, capture_output=True, text=True)
            if archive.stderr:
                print(archive.stderr, file=sys.stderr, end='')
            if archive.returncode:
                return archive.returncode
            receipt = json.loads(archive.stdout)
            imports = receipt.get('imports', [])
            if len(imports) != 1 or not isinstance(imports[0].get('report'), str):
                raise ValueError('History import did not return one retained report')
            retained = Path(imports[0]['report']).resolve(strict=True)
            retained.relative_to((HERE / 'history').resolve())
            report = str(retained)
            print(json.dumps(receipt), file=sys.stderr)
        command += [report, '--registry', absolute(args.registry)]
        return subprocess.run(command, env=env).returncode
    config = Path(args.config).expanduser().resolve()
    if not config.is_file():
        raise ValueError('Config not found: ' + str(config) + '; run setup and edit config.local.json')
    if args.command == 'doctor':
        current = REPOSITORY / 'build_products' / 'axe'
        axe = explicit_axe(args.axe) if args.axe else (current if current.is_file() else None)
        return run_configured(command, config, env, axe=axe).returncode
    tools = args.tools
    if tools is None and not args.rerun_competitors:
        reused = recorded_competitors(json.loads(config.read_text(encoding='utf-8')),
                                      args.scenarios or SCENARIOS, HERE / 'history')
        for name, record in reused.items():
            print(json.dumps({'phase': 'reuse-history', 'tool': name, **record}), file=sys.stderr, flush=True)
        if reused:
            tools = [name for name in TOOLS if name not in reused]
    output = Path(absolute(args.output)) if args.output else artifact_directory()
    # A run measures the current source unless an explicit build is named.
    axe = explicit_axe(args.axe) if args.axe else build_current_axe(env, output.with_name(output.name + '-axe'))
    command += ['--output', str(output), '--repeat', str(args.repeat),
                '--registry', absolute(args.registry)]
    if tools:
        command += ['--tools', *tools]
    if args.scenarios:
        command += ['--scenarios', *args.scenarios]
    result = run_configured(command, config, env, artifacts=True, axe=axe)
    # Keep failed and interrupted runs as well as passes. History never accepts a baseline.
    if (output / 'summary.json').is_file():
        archive = subprocess.run([str(local_python), str(HERE / 'history.py'), 'import', str(output),
                                  '--root', str(HERE / 'history'), '--json'], env=env, stdout=sys.stderr)
        if archive.returncode and result.returncode == 0:
            return archive.returncode
    return result.returncode


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments or (arguments[0].startswith('-') and arguments[0] not in ('-h', '--help')):
        arguments.insert(0, 'run')
    args = parser().parse_args(arguments)
    try:
        return dispatch(args)
    except KeyboardInterrupt:
        print(json.dumps({'status': 'interrupted'}), file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(json.dumps({'status': 'error', 'reason': str(error)}), file=sys.stderr)
        return 2
