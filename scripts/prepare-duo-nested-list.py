#!/usr/bin/env python3
"""Expose the normal nested list with one public page swipe, without injected state."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
from types import SimpleNamespace
import time

parser=argparse.ArgumentParser()
parser.add_argument('--evidence-root',type=Path,required=True)
parser.add_argument('--out',type=Path,required=True)
args=parser.parse_args()
base=args.evidence_root.resolve()
context=json.loads((base/'context.json').read_text())
args.out.mkdir(exist_ok=False)
spec=importlib.util.spec_from_file_location('complete',base/'verify-complete.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
a=SimpleNamespace(output=args.out,axe=Path('/Volumes/Developer/AXe/.build/out/Products/Debug/axe'),
    udid='3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463',screen_id=1,screen_uuid=context['uuid'],
    pid=context['pid'],rotation=270,state_file=Path(context['stateFile']))
bound=m.bind_state(a,'container-before')
description=m.invoke(a,'describe-before','describe-ui',[],ax=True)
selected=description['context']
assert selected['bootIdentity']==context['boot']
before=m.read_state(a,selected);m.write_json(args.out/'state-before.json',before)
assert before['activeWindowTouches']==0 and not before['textFocused']
nodes=list(m.walk(description['ax']['roots']))
viewport=m.rect(m.exact_node(a,nodes,'feature.mainScroll'))
label=m.rect(m.exact_node(a,nodes,'feature.switchLabel'))
inner=m.rect(m.exact_node(a,nodes,'feature.list'))
needed=inner[1]+inner[3]-viewport[1]-viewport[3]
assert needed>0 and inner[3]<=viewport[3]
start=(label[0]+label[2]/2,label[1]+label[3]/2)
end=(start[0],start[1]-needed-20)
assert all(m.contains(viewport,p) for p in [start,end])
assert m.exact_node(a,nodes,'feature.switchLabel')['type']=='StaticText'
for key in ['tap','pad','slider','switch','text','list']:
    assert not m.contains(m.rect(m.exact_node(a,nodes,'feature.'+key)),start)
m.write_json(args.out/'geometry.json',dict(viewport=viewport,label=label,list=inner,start=start,end=end,needed=needed))
receipt=m.invoke(a,'expose-list','swipe',['--start-x',str(start[0]),'--start-y',str(start[1]),
    '--end-x',str(end[0]),'--end-y',str(end[1]),'--duration','0.5','--delta','10'])
assert receipt['context']==selected and receipt['cleanup']=='notNeeded'
deadline=time.monotonic()+5;anchor=None;since=None
while True:
    after=m.read_state(a,selected)
    now=time.monotonic()
    if after['activeWindowTouches']==0 and after['pageOffsetY']>before['pageOffsetY']:
        if after!=anchor:anchor=after;since=now
        if now-since>=0.5:break
    assert now<deadline,'Normal page did not settle; no input replay'
    time.sleep(0.05)
m.write_json(args.out/'state-after.json',after)
for key in ['slider','switchOn','text','textFocused','listOffsetY','pinchScale','rotationRadians','panX','panY']:
    assert before[key]==after[key],key
trace=m.suffix(before,after,'windowTouchTrace','windowTraceDropped')
assert len({row['contactID'] for row in trace})==1
assert trace[0]['phase']=='windowTouchBegan' and trace[-1]['phase']=='windowTouchEnded'
assert all(row['phase']=='windowTouchMoved' for row in trace[1:-1])
assert m.near((trace[0]['x'],trace[0]['y']),start) and m.near((trace[-1]['x'],trace[-1]['y']),end)
assert m.suffix(before,after,'recognizerTrace','recognizerTraceDropped')==[]
window={'windowTouchBegan','windowTouchMoved','windowTouchEnded','windowTouchCancelled'}
assert all(after['counts'].get(k,0)==before['counts'].get(k,0) for k in set(before['counts'])|set(after['counts']) if k not in window)
final=m.invoke(a,'describe-after','describe-ui',[],ax=True)
assert final['context']==selected and m.bind_state(a,'container-after')==bound
assert m.read_state(a,selected)==after
finalnodes=list(m.walk(final['ax']['roots']))
newviewport=m.rect(m.exact_node(a,finalnodes,'feature.mainScroll'))
newlist=m.rect(m.exact_node(a,finalnodes,'feature.list'))
assert viewport==newviewport
assert m.contains(viewport,(newlist[0],newlist[1])) and m.contains(viewport,(newlist[0]+newlist[2],newlist[1]+newlist[3]))
result=dict(status='NORMAL_PAGE_EXPOSED_NESTED_LIST',beforePage=before['pageOffsetY'],afterPage=after['pageOffsetY'],
    listOffset=after['listOffsetY'],heldTouches=0,context=selected,pid=a.pid)
m.write_json(args.out/'result.json',result);print(json.dumps(result))
