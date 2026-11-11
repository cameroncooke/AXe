#!/usr/bin/env python3
"""Serial, versioned UI benchmarks against the original XcodeBuildMCP tasks."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid

from adapters import TOOLS, inspect_tool
from baselines import accept_baseline, compare_registry, read_result, validate_result
from environment import app_identity, digest, host_environment, tree_digest
from monitor import resource_sample, run_monitored
from preparation import prepare
from scoring import score_run, token_totals
from suite import make_suite, skill_name

HERE = Path(__file__).resolve().parent
SCENARIOS = ('weather', 'reminders', 'contacts')


def save(file, value):
    Path(file).write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + '\n')


def event(phase, **values):
    print(json.dumps({'phase': phase, **values}), file=sys.stderr, flush=True)


def load_config(file):
    value = json.loads(Path(file).read_text())
    for key in ('xcodebuildmcp', 'developerDir', 'weatherProject', 'setupAxe'):
        source = Path(value[key]).expanduser()
        if not source.is_absolute():
            raise ValueError(key + ' must be an absolute path')
        value[key] = str(source.resolve(strict=True))
    if not re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', value['simulator']):
        raise ValueError('simulator must be an explicit UUID')
    value.setdefault('model', 'claude-opus-4-7')
    value.setdefault('maxClaudeSeconds', 900)
    if type(value['maxClaudeSeconds']) is not int or not 30 <= value['maxClaudeSeconds'] <= 1800:
        raise ValueError('maxClaudeSeconds must be 30 through 1800')
    if type(value.get('allowTestRecordCleanup', False)) is not bool:
        raise ValueError('allowTestRecordCleanup must be a boolean')
    value.setdefault('preparationProfiles', {})
    return value


def inputs(config):
    xbm = Path(config['xcodebuildmcp'])
    return {
        'harnessSHA256': tree_digest(xbm, ['benchmarks/claude-ui/run.ts',
            'src', 'benchmarks/claude-ui/parse_claude_conversation.py',
            'package.json', 'package-lock.json', 'provenance.json', 'verify-provenance.mjs']),
        'scorerSHA256': tree_digest(HERE, ['scoring.py', 'transcript.py']),
        # AXe's official skill is in this repository. FlowDeck's and RocketSim's come with the
        # installed tool, so each report records the hash of the skill tree it actually received.
        'guideSetSHA256': tree_digest(HERE.parent, ['agent-plugin/skills/axe']),
        'sharedRulesSHA256': digest(HERE / 'shared-rules.md'),
        'runnerSHA256': tree_digest(HERE, ['benchmark.py', 'suite.py', 'preparation.py',
                                         'environment.py', 'monitor.py', 'processes.py', 'adapters.py']),
    }


def tool_info(config, name):
    spec = config['tools'][name]
    return {'name': name, **inspect_tool(name, spec['executable'], spec.get('app'))}


def service_ready(tool, env):
    if tool['name'] != 'rocketsim':
        return {'status': 'not-required'}
    argv = [tool['executable'], 'status']
    result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=15)
    value = json.loads(result.stdout)
    data = value.get('data', {})
    ready = (result.returncode == 0 and value.get('ok') is True
             and data.get('rocket_sim_running') is True and data.get('ipc_reachable') is True)
    return {'status': 'ready' if ready else 'blocked', 'argv': argv,
            'exitCode': result.returncode, 'response': value,
            'reason': None if ready else 'Open RocketSim and verify its CLI status before running the suite.'}


def doctor(config, env):
    result = {'schema': 'axe.agent-benchmark.doctor', 'schemaVersion': 1, 'tools': {}}
    for name in TOOLS:
        try:
            identity = tool_info(config, name)
            readiness = service_ready(identity, env)
            result['tools'][name] = {**identity, 'service': readiness,
                                     'status': 'blocked' if readiness['status'] == 'blocked' else 'ready'}
        except Exception as error:
            result['tools'][name] = {'status': 'blocked', 'reason': str(error)}
    for key, action in (
        ('environment', lambda: host_environment(config['simulator'], config['developerDir'], env)),
        ('inputs', lambda: inputs(config)),
        ('setupTool', lambda: inspect_tool('axe', config['setupAxe'])),
    ):
        try:
            result[key] = {'status': 'ready', **action()}
        except Exception as error:
            result[key] = {'status': 'blocked', 'reason': str(error)}
    result['tokenizer'] = token_totals([])
    tsx = Path(config['xcodebuildmcp']) / 'node_modules/.bin/tsx'
    result['runnerDependency'] = {'status': 'ready' if tsx.is_file() else 'blocked', 'path': str(tsx)}
    result['ready'] = (all(row['status'] == 'ready' for row in result['tools'].values())
                       and all(result[key]['status'] == 'ready' for key in
                               ('environment', 'inputs', 'setupTool', 'runnerDependency'))
                       and result['tokenizer']['tokenStatus'] == 'measured')
    return result


@contextmanager
def simulator_lock(udid):
    file = Path(tempfile.gettempdir()) / ('axe-agent-benchmark-' + udid.lower() + '.lock')
    fd = os.open(file, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError('Invalid simulator lock file')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def lifecycle(config, app, env, output, launch=False):
    argv = ['/usr/bin/xcrun', 'simctl', 'launch' if launch else 'terminate',
            config['simulator'], app['bundleId']]
    result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
    save(output, {'argv': argv, 'exitCode': result.returncode,
                  'stdout': result.stdout, 'stderr': result.stderr})
    # A stopped or not-yet-installed app is a valid termination outcome.
    absent = ('found nothing to terminate' in result.stderr.lower() or
              'not running' in result.stderr.lower() or
              'no such process' in result.stderr.lower())
    if result.returncode and (launch or not absent):
        raise RuntimeError('Normal app lifecycle failed: ' + result.stderr[-1000:])
    if launch:
        match = re.fullmatch(re.escape(app['bundleId']) + r':\s*([1-9][0-9]*)\s*', result.stdout.strip())
        if match is None:
            raise RuntimeError('Normal app launch did not return an application PID')
        return int(match.group(1))
    return None


REMINDERS_GROUP = 'group.com.apple.reminders'
REMINDERS_FIRST_OPENED_KEY = 'firstTimeAppForegroundingDate'


def reset_reminders_review_gate(config, env, output, now=None):
    """Set the date Reminders records as its first foreground to now, so every job starts with its review gate closed.

    About seven days after that date, Reminders on the iOS 27.2 simulator runtime asks remindd for a review count
    two seconds after each completion. remindd rejects the request and closes the connection that the list refresh
    is also using, so the completed row stays on screen and later completions read as stale
    (docs/release-readiness.md, Phase 13). Run after Reminders is terminated, outside the benchmark clock. The
    write goes through the simulator's preferences daemon, which the app reads, and is read back before the job."""
    when = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0)
    text = when.strftime('%Y-%m-%d %H:%M:%S +0000')
    udid = config['simulator']
    locate = ['/usr/bin/xcrun', 'simctl', 'get_app_container', udid, 'com.apple.reminders', REMINDERS_GROUP]
    found = subprocess.run(locate, env=env, capture_output=True, text=True, timeout=30)
    group = Path(found.stdout.strip())
    if found.returncode or not group.is_absolute() or group.name == '' or udid not in group.parts:
        raise RuntimeError('The Reminders app group container was not found: ' + found.stderr[-500:])
    domain = str(group / 'Library/Preferences' / REMINDERS_GROUP)

    def defaults(*arguments):
        argv = ['/usr/bin/xcrun', 'simctl', 'spawn', udid, 'defaults', *arguments]
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
        return {'argv': argv, 'exitCode': result.returncode,
                'stdout': result.stdout.strip(), 'stderr': result.stderr.strip()[-500:]}

    before = defaults('read', domain, REMINDERS_FIRST_OPENED_KEY)
    write = defaults('write', domain, REMINDERS_FIRST_OPENED_KEY, '-date', text)
    after = defaults('read', domain, REMINDERS_FIRST_OPENED_KEY)
    receipt = {'domain': domain, 'key': REMINDERS_FIRST_OPENED_KEY, 'value': text,
               'previous': before['stdout'] if before['exitCode'] == 0 else None,
               'calls': [before, write, after]}
    save(output, receipt)
    if write['exitCode'] or after['exitCode'] or after['stdout'] != text:
        raise RuntimeError('The Reminders first-opened date was not set: ' + (write['stderr'] or after['stdout']))
    return {'value': text, 'previous': receipt['previous']}


def setup_policy(scenario):
    policy = ('warm-device;normal-termination;exact-owned-record-cleanup;harness-build-install-launch-v1;'
              'official-tool-skill-v1')
    return policy + (';reminders-review-gate-closed-v1' if scenario == 'reminders' else '')


def official_skill(config, name, identity, env):
    """The tool's own agent skill, unedited, as its vendor ships it.

    AXe: the skill `axe init` installs (agent-plugin/skills/axe). RocketSim: the skill in its app bundle.
    FlowDeck: the pack `flowdeck ai install-skill` installs, fetched once per FlowDeck version into
    the ignored cache."""
    if name == 'axe':
        return HERE.parent / 'agent-plugin' / 'skills' / 'axe'
    if name == 'rocketsim':
        skill = Path(config['tools']['rocketsim']['app']) / 'Contents/Resources/Agent-Skill/rocketsim'
        if not (skill / 'SKILL.md').is_file():
            raise RuntimeError('RocketSim does not ship an agent skill at ' + str(skill))
        return skill
    version = str(identity.get('version') or '')
    if not re.fullmatch(r'[0-9][0-9A-Za-z.\-]*', version):
        raise RuntimeError('FlowDeck reported no usable version for its skill pack')
    cache = HERE / '.cache' / 'skills' / ('flowdeck-' + version)
    skill = cache / '.claude' / 'skills' / 'flowdeck'
    if not (skill / 'SKILL.md').is_file():
        cache.mkdir(parents=True, exist_ok=True)
        argv = [identity['executable'], 'ai', 'install-skill', '--agent', 'claude', '--mode', 'project']
        result = subprocess.run(argv, cwd=cache, env=env, capture_output=True, text=True, timeout=300)
        if result.returncode or not (skill / 'SKILL.md').is_file():
            raise RuntimeError('FlowDeck did not install its skill pack: ' + (result.stderr or result.stdout)[-500:])
    header = (skill / 'SKILL.md').read_text(encoding='utf-8')[:2000]
    if re.search(r'^version:\s*"?' + re.escape(version) + r'"?\s*$', header, re.M) is None:
        raise RuntimeError('The cached FlowDeck skill pack is not version ' + version)
    return skill


def install_weather(config, app, env, output):
    """Build and install Weather before the measured task, outside the benchmark clock."""
    derived = HERE / '.cache' / 'weather-derived-data'
    xcodebuild = str(Path(config['developerDir']) / 'usr/bin/xcodebuild')
    build = [xcodebuild, '-project', app['project'], '-scheme', app['scheme'], '-configuration', 'Debug',
             '-sdk', 'iphonesimulator', '-destination', 'id=' + config['simulator'],
             '-derivedDataPath', str(derived), 'build']
    with (output / 'weather-build.log').open('w', encoding='utf-8') as log:
        result = subprocess.run(build, env=env, stdout=log, stderr=subprocess.STDOUT, text=True, timeout=1800)
    built = derived / 'Build/Products/Debug-iphonesimulator/Weather.app'
    if result.returncode or not built.is_dir():
        raise RuntimeError('The Weather build failed; see weather-build.log')
    install = ['/usr/bin/xcrun', 'simctl', 'install', config['simulator'], str(built)]
    installed = subprocess.run(install, env=env, capture_output=True, text=True, timeout=120)
    save(output / 'weather-install.json', {'build': build, 'buildExitCode': result.returncode, 'install': install,
                                           'installExitCode': installed.returncode, 'stderr': installed.stderr[-1000:]})
    if installed.returncode:
        raise RuntimeError('Installing Weather failed: ' + installed.stderr[-500:])


def contract(config, scenario, host, app, hashes):
    fields = ('claudeVersion', 'deviceType', 'runtimeVersion', 'screenWidth', 'screenHeight',
              'rotation', 'hostOS', 'hostBuild', 'hostArchitecture', 'hostModel', 'xcodeVersion', 'nodeVersion')
    return {**hashes, **{key: host[key] for key in fields},
            'taskSHA256': digest(HERE / 'tasks' / (scenario + '.md')),
            'appSourceSHA256': app['sourceSHA256'], 'model': config['model'], 'modelVersion': 'unobserved',
            'initialInventorySHA256': hashlib.sha256(json.dumps(
                config.get('preparationProfiles', {}).get(scenario) if scenario != 'weather' else None,
                sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'setupPolicy': setup_policy(scenario),
            'tokenizer': 'o200k_base', 'tokenScope': 'all-returned-tool-text;images-separate',
            'maxClaudeSeconds': config['maxClaudeSeconds']}


def archive_run(native, output):
    """Keep raw proof; leave build products in the original runner directory."""
    destination = output / 'evidence'
    destination.mkdir()
    hashes = {}
    for file in native.iterdir():
        if file.is_file() and not file.is_symlink():
            shutil.copy2(file, destination / file.name)
            hashes[file.name] = digest(destination / file.name)
    save(destination / 'archive.json', {'source': str(native), 'sha256': hashes})
    return destination


def run_case(config, scenario, name, output, env):
    output.mkdir(parents=True)
    result = {'schema': 'axe.agent-benchmark.result', 'schemaVersion': 1,
              'runId': output.name, 'scenario': scenario, 'status': 'blocked',
              'tool': {'name': name}, 'contract': {}, 'metrics': {},
              'correctness': {'status': 'blocked', 'checks': []}}
    try:
        result['tool'] = tool_info(config, name)
        result['service'] = service_ready(result['tool'], env)
        if result['service']['status'] == 'blocked':
            raise RuntimeError(result['service']['reason'])
        host = host_environment(config['simulator'], config['developerDir'], env)
        app = app_identity(scenario, config, env)
        hashes = inputs(config)
        result['environment'], result['app'] = host, app
        result['contract'] = contract(config, scenario, host, app, hashes)
        save(output / 'before.json', {'tool': result['tool'], 'environment': host, 'inputs': hashes})
        sample = resource_sample()
        save(output / 'resources-before.json', sample)
        if any(p['rssBytes'] > 20 * 1024**3 for p in sample['processes']):
            raise RuntimeError('A monitored process exceeds 20 GiB RSS; no job started')
        lifecycle(config, app, env, output / 'terminate-before.json')
        preparation_pid = None
        if scenario != 'weather':
            preparation_pid = lifecycle(config, app, env, output / 'launch-preparation.json', launch=True)
        prep = prepare(scenario, config['setupAxe'], config['simulator'], output / 'preparation',
                       config.get('allowTestRecordCleanup', False), config['preparationProfiles'].get(scenario),
                       env=env, expected_pid=preparation_pid)
        result['preparation'] = prep
        if prep['status'] != 'ready':
            raise RuntimeError('Preparation: ' + prep.get('reason', 'not ready'))
        lifecycle(config, app, env, output / 'terminate-ready.json')
        if scenario == 'reminders':
            result['reviewGate'] = reset_reminders_review_gate(config, env, output / 'review-gate.json')
        if scenario == 'weather':
            install_weather(config, app, env, output)
        skill_source = official_skill(config, name, result['tool'], env)
        suite = make_suite(config, scenario, name, result['tool'], app, output, skill_source=skill_source)
        skill_dir = output / 'skills' / skill_name(name)
        result['tool']['skillSource'] = str(skill_source)
        result['tool']['guideSHA256'] = tree_digest(skill_dir)
        # The app is running before the clock starts; the measured task is UI interaction only.
        result['taskLaunch'] = {'pid': lifecycle(config, app, env, output / 'launch-task.json', launch=True)}
        tsx = Path(config['xcodebuildmcp']) / 'node_modules/.bin/tsx'
        if not tsx.is_file():
            raise RuntimeError('Run ./benchmarks/run setup to install the local benchmark dependencies')
        argv = [str(tsx), 'benchmarks/claude-ui/run.ts', '--suite', str(output / 'suite.json'),
                '--model', config['model'], '--json']
        event('running', scenario=scenario, tool=name, version=result['tool']['version'], runId=output.name)
        execution = run_monitored(argv, config['xcodebuildmcp'], env, output / 'execution',
                                  timeout=config['maxClaudeSeconds'] + 120,
                                  model_run_root=Path(config['xcodebuildmcp']) / 'out.nosync/claude-benchmarks' / suite['name'])
        result['execution'] = execution
        if (execution['stopReason'] or '').startswith('KeyboardInterrupt'):
            raise KeyboardInterrupt()
        native_parent = Path(config['xcodebuildmcp']) / 'out.nosync/claude-benchmarks' / suite['name']
        runs = list(native_parent.glob('*/claude.jsonl'))
        if len(runs) != 1:
            raise RuntimeError('Expected one raw model transcript; runner did not produce one')
        evidence = archive_run(runs[0].parent, output)
        score = score_run(evidence, scenario, name,
                          expected_executable=result['tool']['executable'], expected_udid=config['simulator'],
                          expected_setup={**app, 'developerDir': config['developerDir'],
                                          'udid': config['simulator'], 'runDirectory': str(runs[0].parent),
                                          'launchedByHarness': True})
        result.update({key: score[key] for key in ('status', 'correctness', 'metrics', 'warnings', 'transcriptSHA256')})
        result['observedRuntime'] = score['observedRuntime']
        result['contract']['modelVersion'] = score['observedRuntime'].get('model') or 'unobserved'
        result['contract']['tokenizerVersion'] = result['metrics'].get('tokenizerVersion', 'unavailable')
        after_tool = tool_info(config, name)
        after_host = host_environment(config['simulator'], config['developerDir'], env)
        after_app = app_identity(scenario, config, env)
        stable = (inputs(config) == hashes and
                  after_tool['binarySHA256'] == result['tool']['binarySHA256'] and
                  after_tool['companionApp'] == result['tool']['companionApp'] and
                  after_tool.get('runtimeFiles') == result['tool'].get('runtimeFiles') and
                  after_app['sourceSHA256'] == app['sourceSHA256'] and
                  all(after_host[k] == host[k] for k in host if k != 'deviceName'))
        for identity, passed, reason in (
            ('inputs.unchanged', stable, 'Tool, app, harness and environment must remain unchanged.'),
            ('model.expected', result['contract']['modelVersion'] == config['model'] and
             score['observedRuntime'].get('initializationCount') == 1 and
             score['observedRuntime'].get('claudeVersion') == host['claudeVersion'].split()[0],
             'Observed model and Claude version must match the requested environment.'),
            ('runner.completed', execution['exitCode'] == 0 and not execution['stopReason'], str(execution['stopReason'])),
        ):
            result['correctness']['checks'].append({'id': identity, 'status': 'passed' if passed else 'unverified', 'reason': reason})
            if not passed and result['status'] == 'passed':
                result['status'] = 'unverified'
        result['correctness']['status'] = result['status']
    except KeyboardInterrupt:
        result['reason'] = 'Interrupted by user; task is not accepted.'
        result['status'] = result['correctness']['status'] = 'unverified'
        raise
    except Exception as error:
        result['reason'] = type(error).__name__ + ': ' + str(error)
        result['status'] = 'blocked' if not result.get('execution') else 'unverified'
        result['correctness']['status'] = result['status']
    finally:
        validate_result(result)
        save(output / 'report.json', result)
        event('finished', scenario=scenario, tool=name, status=result['status'], report=str(output / 'report.json'))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('doctor', 'run'):
        sub = commands.add_parser(name)
        sub.add_argument('--config', required=True)
        if name == 'run':
            sub.add_argument('--tools', nargs='+', choices=TOOLS, default=list(TOOLS))
            sub.add_argument('--scenarios', nargs='+', choices=SCENARIOS, default=list(SCENARIOS))
            sub.add_argument('--output', required=True)
            sub.add_argument('--repeat', type=int, default=1)
            sub.add_argument('--registry')
    for name in ('compare', 'accept'):
        sub = commands.add_parser(name)
        sub.add_argument('result')
        sub.add_argument('--registry', required=True)
    args = parser.parse_args()
    if args.command in ('accept', 'compare'):
        value = (accept_baseline(args.registry, args.result) if args.command == 'accept'
                 else compare_registry(read_result(args.result), args.registry))
        print(json.dumps(value, indent=2))
        return 0
    config = load_config(args.config)
    env = {**os.environ, 'DEVELOPER_DIR': config['developerDir']}
    if args.command == 'doctor':
        result = doctor(config, env)
        print(json.dumps(result, indent=2))
        return 0 if result['ready'] else 1
    if not 1 <= args.repeat <= 10:
        raise ValueError('--repeat must be 1 through 10')
    output = Path(args.output).expanduser().absolute()
    output.mkdir(parents=True, exist_ok=False)
    save(output / 'config.json', config)
    result = {'schema': 'axe.agent-benchmark.matrix', 'schemaVersion': 1, 'runs': []}
    with simulator_lock(config['simulator']):
        for repeat in range(args.repeat):
            for scenario in args.scenarios:
                for name in args.tools:
                    run_id = f'axe-bench-{scenario}-{name}-{uuid.uuid4().hex[:12]}'
                    try:
                        case = run_case(config, scenario, name, output / run_id, env)
                    except KeyboardInterrupt:
                        receipt = output / run_id / 'report.json'
                        if receipt.is_file():
                            result['runs'].append({'report': str(receipt), 'repeat': repeat + 1,
                                                   **read_result(receipt)})
                        result['interrupted'] = True
                        save(output / 'summary.json', result)
                        raise
                    row = {'report': str(output / run_id / 'report.json'), 'repeat': repeat + 1, **case}
                    if args.registry:
                        row['baselineComparison'] = compare_registry(case, args.registry)
                    result['runs'].append(row)
                    save(output / 'summary.json', result)
                    if case.get('execution', {}).get('cleanup', {}).get('complete') is False:
                        raise RuntimeError('Owned process cleanup is incomplete; no further job can start')
    print(json.dumps(result, indent=2))
    return 0 if all(row['status'] == 'passed' for row in result['runs']) else 1


if __name__ == '__main__':
    def stop_requested(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, stop_requested)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(json.dumps({'status': 'interrupted'}), file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print(json.dumps({'status': 'error', 'reason': str(error)}), file=sys.stderr)
        sys.exit(2)
