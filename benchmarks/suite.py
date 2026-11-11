"""Generate an isolated XcodeBuildMCP model benchmark suite from pinned inputs."""
from __future__ import annotations

import json
from pathlib import Path
import re
import shlex
import shutil

from adapters import allowed_tools, tool_matchers


ROOT = Path(__file__).resolve().parent
# Every tool runs with its own official agent skill, unedited: AXe the one `axe init` installs,
# FlowDeck the pack `flowdeck ai install-skill` installs, RocketSim the one in its app bundle.
SHIPPED_AXE_SKILL = ROOT.parent / 'Skills' / 'CLI' / 'axe'


def skill_name(tool):
    """The installed skill's directory and activation name for a tool."""
    return tool


def _text(value, name):
    if not isinstance(value, str) or not value or any(c in value for c in ('\x00', '\r', '\n')):
        raise ValueError('Invalid suite field: ' + name)
    return value


def make_suite(config, scenario, tool, identity, app, output, skill_source=None):
    """Write the skill, copied task and suite; do not run tools or the simulator.

    The harness builds, installs and launches the app before the measured task, so the agent's
    work is UI reading and input only and every tool's skill applies only to that part."""
    if scenario not in ('weather', 'reminders', 'contacts'):
        raise ValueError('Unknown benchmark scenario: ' + str(scenario))
    output = Path(output).resolve()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*', output.name):
        raise ValueError('Suite directory name must contain only letters, digits and hyphens')
    executable = _text(identity['executable'], 'executable')
    udid = _text(config['simulator'], 'simulator')
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
    source = Path(skill_source) if skill_source is not None else (SHIPPED_AXE_SKILL if tool == 'axe' else None)
    if source is None or not (source / 'SKILL.md').is_file():
        raise ValueError('The official ' + tool + ' skill was not found: ' + str(source))
    setup = [
        'This benchmark measures UI interaction only. The harness has already built, installed and launched '
        'the app, and it is running on the simulator. Do not build, install, launch or terminate apps.',
        'Use only the assigned CLI for UI reading and input: ' + shlex.quote(executable),
        'Target existing warm simulator UDID: ' + udid,
        'Application bundle: ' + bundle,
        'Run artifacts directory: {runDirectory}',
        'The installed skill writes `' + Path(executable).name + '` in its examples; run the assigned CLI '
        + shlex.quote(executable) + ' in its place, and target simulator ' + udid + ' explicitly on every command.',
    ]
    allowed = allowed_tools(tool, executable)
    xbm_root = Path(_text(config['xcodebuildmcp'], 'xcodebuildmcp'))
    if not xbm_root.is_absolute():
        raise ValueError('xcodebuildmcp must be absolute')
    artifact_root = str(xbm_root.resolve() / 'out.nosync/claude-benchmarks' / output.name)
    # Edit rules also control shell output redirection. A single * matches one
    # timestamp component, then one file name, not arbitrary descendants: a PNG for
    # screenshots, JSON or text for a tool's read written once to a file.
    literal_root = re.sub(r'([\\*?\[\]])', r'\\\1', artifact_root)
    allowed += ['Edit(/' + literal_root + '/*/*.' + suffix + ')' for suffix in ('png', 'json', 'txt')]
    # A tool's own reference may write a read to the temporary directory (RocketSim: /tmp/rs-snap.json).
    allowed += ['Edit(/' + root + '/*.' + suffix + ')' for root in ('/tmp', '/private/tmp')
                for suffix in ('png', 'json', 'txt')]
    matchers = tool_matchers(tool, executable)
    output.mkdir(parents=True, exist_ok=True)
    skill = output / 'skills' / skill_name(tool)
    skill.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, skill, ignore=shutil.ignore_patterns('.DS_Store'))
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
            'activateSkill': skill_name(tool), 'isolatedWorkingDirectory': True,
            'extraArgs': ['--setting-sources', 'project,local'],
            'appendSystemPrompt': '\n'.join(setup) + '\n\n' + rules,
        },
        'toolAnalysis': {'matchers': matchers},
    }
    with (output / 'suite.json').open('x', encoding='utf-8') as destination:
        json.dump(suite, destination, indent=2)
        destination.write('\n')
    return suite
