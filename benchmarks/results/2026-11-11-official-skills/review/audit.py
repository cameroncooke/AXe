"""Per-run audit of one benchmark transcript: what the agent ran and read, and anything that breaks the rules.
Usage: audit.py <run-folder> [--full]"""
import json, re, sys
from pathlib import Path
run = Path(sys.argv[1]); full = '--full' in sys.argv
report = json.loads((run / 'report.json').read_text())
tool = report['tool']['name']; exe = report['tool'].get('executable', '')
skill_dir = None
uses, results, texts, order = {}, {}, [], []
for line in (run / 'evidence/claude.jsonl').read_text().splitlines():
    try: o = json.loads(line)
    except ValueError: continue
    if isinstance(o, dict) and o.get('cwd') and skill_dir is None: skill_dir = str(Path(o['cwd']) / '.claude/skills')
    m = o.get('message') if isinstance(o, dict) else None
    cs = m.get('content') if isinstance(m, dict) else None
    if isinstance(cs, str) and m.get('role') == 'assistant': texts.append(cs)
    for c in cs if isinstance(cs, list) else []:
        if not isinstance(c, dict): continue
        if c.get('type') == 'tool_use': uses[c['id']] = c; order.append(c['id'])
        elif c.get('type') == 'tool_result': results[c['tool_use_id']] = c
        elif c.get('type') == 'text' and m.get('role') == 'assistant': texts.append(c['text'])
def txt(r):
    t = r.get('content') if r else ''
    return ' '.join(x.get('text', '') if isinstance(x, dict) else str(x) for x in t) if isinstance(t, list) else str(t)
flags = []
names = {'axe': 'axe', 'flowdeck': 'flowdeck', 'rocketsim': 'rocketsim'}
for n, i in enumerate(order, 1):
    u = uses[i]; r = results.get(i); inp = u['input']; t = txt(r)
    if u['name'] == 'Bash':
        cmd = inp.get('command', '')
        first = cmd.strip().split()[0] if cmd.strip() else ''
        if Path(first.strip("'\"")).name != names[tool]:
            flags.append((n, 'non-tool command', cmd[:200]))
        if re.search(r'\b(cat|grep|sed|awk|find|ls|head|tail|sqlite3|defaults|plutil|strings)\b', cmd) and Path(first.strip("'\"")).name != names[tool]:
            flags.append((n, 'file/inspection command', cmd[:200]))
        if re.search(r'\.swift|\.xcodeproj|Containers/|Library/Preferences|\.sqlite|\.db\b|AddressBook|Reminders/|benchmarks/apps', cmd):
            flags.append((n, 'touches app source/storage', cmd[:200]))
        if r and r.get('is_error') and re.search(r'requires approval|not allowed|denied', t):
            flags.append((n, 'permission denied', cmd[:160]))
        for f in ('clear-state', 'open-url', 'config set', 'config reset', 'license', ' update', 'doctor', 'simulator boot', 'simulator erase', 'preview'):
            if f in cmd and Path(first.strip("'\"")).name == names[tool]:
                flags.append((n, 'notable tool command: ' + f.strip(), cmd[:160]))
    elif u['name'] == 'Read':
        p = inp.get('file_path', '')
        kind = 'skill' if skill_dir and p.startswith(skill_dir) else 'run-dir' if '/out.nosync/claude-benchmarks/' in p else 'tmp' if p.startswith(('/tmp', '/private/tmp')) else 'tool-output?' 
        if kind == 'tool-output?':
            flags.append((n, 'read outside run/skill/tmp', p[:200]))
        if re.search(r'\.swift$|\.xcodeproj|/apps/|Containers/|Preferences|\.sqlite', p):
            flags.append((n, 'reads app source/storage', p[:200]))
    elif u['name'] == 'Write':
        p = inp.get('file_path', '')
        if '/out.nosync/claude-benchmarks/' not in p:
            flags.append((n, 'write outside run dir', p[:200]))
    else:
        flags.append((n, 'unexpected tool ' + u['name'], json.dumps(inp)[:160]))
m = report.get('metrics', {})
print('==', run.name, report['status'], 'calls', m.get('totalCalls'), 'help', m.get('helpCalls'), 'err', m.get('errorCalls'),
      'img', m.get('imageCount'), 's', round(m.get('elapsedSeconds') or 0), 'tok', m.get('returnedTextTokens'),
      'skill', Path(report['tool'].get('skillSource', '')).name, report['tool'].get('version'))
for c in report['correctness']['checks']:
    if c['status'] != 'passed':
        print('   CHECK', c['id'], c['status'], '-', (c.get('reason') or '')[:140], json.dumps(c.get('evidence'))[:200])
for f in flags: print('   FLAG', *f)
final = texts[-1] if texts else ''
print('   FINAL:', final[:900 if full else 300].replace('\n', ' '))
