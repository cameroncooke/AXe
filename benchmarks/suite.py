"""Generate an isolated XcodeBuildMCP model benchmark suite from pinned inputs."""
from __future__ import annotations

import json
from pathlib import Path
import re
import shlex

from adapters import allowed_tools, render_guide, tool_matchers


ROOT = Path(__file__).resolve().parent


def _text(value, name):
    if not isinstance(value, str) or not value or any(c in value for c in ('\x00', '\r', '\n')):
        raise ValueError('Invalid suite field: ' + name)
    return value


def make_suite(config, scenario, tool, identity, app, output):
    """Write the skill, copied task and suite; do not run tools or the simulator."""
    if scenario not in ('weather', 'reminders', 'contacts'):
        raise ValueError('Unknown benchmark scenario: ' + str(scenario))
    output = Path(output).resolve()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*', output.name):
        raise ValueError('Suite directory name must contain only letters, digits and hyphens')
    executable = _text(identity['executable'], 'executable')
    udid = _text(config['simulator'], 'simulator')
    developer = Path(_text(config['developerDir'], 'developerDir'))
    if not developer.is_absolute():
        raise ValueError('developerDir must be absolute')
    xcodebuild = str(developer / 'usr/bin/xcodebuild')
    model = _text(config['model'], 'model')
    timeout = config.get('maxClaudeSeconds', 900)
    if type(timeout) is not int or timeout <= 0:
        raise ValueError('maxClaudeSeconds must be a positive integer')
    directory = _text(app['directory'], 'app directory')
    bundle = _text(app['bundleId'], 'bundleId')
    if not Path(directory).is_absolute():
        raise ValueError('App working directory must be absolute')
    rules = (ROOT / 'shared-rules.md').read_text(encoding='utf-8')
    prompt = (ROOT / 'tasks' / (scenario + '.md')).read_text(encoding='utf-8')
    guide = render_guide(tool, executable, udid)
    setup = [
        'Use only the assigned CLI for UI automation: ' + shlex.quote(executable),
        'Target existing warm simulator UDID: ' + udid,
        'Application bundle: ' + bundle,
        'Run artifacts directory: {runDirectory}',
        'DEVELOPER_DIR is ' + str(developer) + '.',
    ]
    allowed = allowed_tools(tool, executable)
    xbm_root = Path(_text(config['xcodebuildmcp'], 'xcodebuildmcp'))
    if not xbm_root.is_absolute():
        raise ValueError('xcodebuildmcp must be absolute')
    artifact_root = str(xbm_root.resolve() / 'out.nosync/claude-benchmarks' / output.name)
    # Edit rules also control shell output redirection. A single * matches one
    # timestamp component, then one PNG filename, not arbitrary descendants.
    literal_root = re.sub(r'([\\*?\[\]])', r'\\\1', artifact_root)
    allowed.append('Edit(/' + literal_root + '/*/*.png)')
    matchers = tool_matchers(tool, executable)
    launch = '/usr/bin/xcrun simctl launch ' + shlex.quote(udid) + ' ' + shlex.quote(bundle)
    if scenario == 'weather':
        project = _text(app['project'], 'project')
        scheme = _text(app['scheme'], 'scheme')
        if not Path(project).is_absolute():
            raise ValueError('Project path must be absolute')
        setup += [
            'App source directory: ' + directory,
            'Project: ' + project,
            'Scheme: ' + scheme + '; configuration: Debug.',
            'Build, install and launch during the measured task. Use one serial public build command:',
            ' '.join([shlex.quote(xcodebuild), '-project', shlex.quote(project), '-scheme',
                      shlex.quote(scheme), '-configuration Debug -sdk iphonesimulator -destination',
                      shlex.quote('id=' + udid), "-derivedDataPath '{runDirectory}/DerivedData' -jobs 1 build"]),
            'Then install the built app with:',
            '/usr/bin/xcrun simctl install ' + shlex.quote(udid)
            + " '{runDirectory}/DerivedData/Build/Products/Debug-iphonesimulator/Weather.app'",
            'Then launch with: ' + launch,
        ]
        allowed += ['Bash(' + shlex.quote(xcodebuild) + ' *)',
                    'Bash(/usr/bin/xcrun simctl install ' + udid + ' *)']
        matchers += [
            {'kind': 'bashCommand', 'commandPrefix': shlex.quote(xcodebuild),
             'shortName': 'setup.build', 'uiAutomation': False},
            {'kind': 'bashCommand', 'commandPrefix': '/usr/bin/xcrun simctl install',
             'shortName': 'setup.install', 'uiAutomation': False},
        ]
    else:
        setup += ['The system app is already installed. Launch it during the measured task:', launch]
    allowed.append('Bash(/usr/bin/xcrun simctl launch ' + udid + ' *)')
    matchers.append({'kind': 'bashCommand', 'commandPrefix': '/usr/bin/xcrun simctl launch',
                     'shortName': 'setup.launch', 'uiAutomation': False})

    output.mkdir(parents=True, exist_ok=True)
    skill = output / 'skills' / (tool + '-benchmark')
    skill.mkdir(parents=True, exist_ok=False)
    (skill / 'SKILL.md').write_text(guide, encoding='utf-8')
    prompt_path = output / 'task.md'
    with prompt_path.open('x', encoding='utf-8') as destination:
        destination.write(prompt)
    suite = {
        'name': output.name, 'prompt': str(prompt_path), 'workingDirectory': directory,
        'temporarySimulator': False, 'sessionDefaults': {'simulatorId': udid},
        'claude': {
            'model': model, 'useMcpServer': False, 'permissionMode': 'default',
            'maxClaudeSeconds': timeout, 'tools': ['Bash', 'Read', 'Write'],
            'allowedTools': list(dict.fromkeys(allowed)), 'skillDirs': [str(skill)],
            'activateSkill': tool + '-benchmark', 'isolatedWorkingDirectory': True,
            'extraArgs': ['--setting-sources', 'project,local'],
            'appendSystemPrompt': '\n'.join(setup) + '\n\n' + rules,
        },
        'toolAnalysis': {'matchers': matchers},
    }
    with (output / 'suite.json').open('x', encoding='utf-8') as destination:
        json.dump(suite, destination, indent=2)
        destination.write('\n')
    return suite
