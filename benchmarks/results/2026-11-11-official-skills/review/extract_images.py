"""Write every image returned to the agent in a transcript to <out>/<run>-call<N>.<ext>."""
import base64, json, sys
from pathlib import Path
run, out = Path(sys.argv[1]), Path(sys.argv[2])
order, uses = [], {}
for line in (run / 'evidence/claude.jsonl').read_text().splitlines():
    try: o = json.loads(line)
    except ValueError: continue
    m = o.get('message') if isinstance(o, dict) else None
    for c in (m.get('content') if isinstance(m, dict) and isinstance(m.get('content'), list) else []):
        if not isinstance(c, dict): continue
        if c.get('type') == 'tool_use': order.append(c['id'])
        if c.get('type') == 'tool_result' and isinstance(c.get('content'), list):
            n = order.index(c['tool_use_id']) + 1 if c['tool_use_id'] in order else 0
            for k, item in enumerate(c['content']):
                if isinstance(item, dict) and item.get('type') == 'image':
                    src = item['source']; ext = src.get('media_type', 'image/png').split('/')[-1]
                    f = out / ('%s-call%02d%s.%s' % (run.name.split('-')[-1], n, '' if k == 0 else '-%d' % k, ext))
                    f.write_bytes(base64.b64decode(src['data'])); print(f)
