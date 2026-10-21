#!/usr/bin/env python3
"""Check saved outer270 gesture evidence without simulator input."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

parser=argparse.ArgumentParser()
parser.add_argument('--evidence-root',type=Path,required=True)
parser.add_argument('--current',action='store_true')
a=parser.parse_args();base=a.evidence_root.resolve()
def read(name):return json.loads((base/name).read_text())
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
manifest=read('candidate.json')
for pin in manifest['dependencies']+manifest['tools']:
    assert digest(base/pin['copy'])==pin['sha256'],pin['copy']
    if a.current:assert digest(Path(pin['path']))==pin['sha256'],pin['path']
spec=importlib.util.spec_from_file_location('complete',base/'verify-complete.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
verified=[]
for case in ['pinch','rotate','two-finger-tap','two-finger-hold','nested-up','nested-down']:
    folder='outer270-'+case
    wrapper,result=read(folder+'/result.json'),read(folder+'/check/result.json')
    assert wrapper['exitCode']==0 and wrapper['reaped'] and wrapper['stopReason'] is None
    assert result['result']=='PASS' and result['context']['rotationDegrees']==270
    assert result['context']['screenID']==1 and result['activeWindowTouches']==0
    before,after=read(folder+'/check/state-before.json'),read(folder+'/check/state-after.json')
    description=read(folder+'/check/describe-receipt.json')
    final=read(folder+'/check/describe-after-receipt.json')
    args=SimpleNamespace(case=case,pid=result['pid'])
    center,frame,capacity=m.geometry(args,description,before)
    verb,extra,counter=m.make_command(args,*center)
    m.grade(args,before,after,counter,center,frame,capacity)
    assert description['context']==final['context']==result['context']
    initial_nodes=list(m.walk(description['ax']['roots']));final_nodes=list(m.walk(final['ax']['roots']))
    for control in ['feature.mainScroll','feature.slider','feature.switch','feature.text','feature.tap']:
        assert m.rect(m.exact_node(args,initial_nodes,control))==m.rect(m.exact_node(args,final_nodes,control))
    if capacity is not None:
        shift=after['listOffsetY']-before['listOffsetY']
        for index in range(1,31):
            name='feature.row.%02d'%index
            first,last=m.rect(m.exact_node(args,initial_nodes,name)),m.rect(m.exact_node(args,final_nodes,name))
            assert m.near((last[0],last[1]),(first[0],first[1]-shift)) and last[2:]==first[2:]
    assert all(json.loads(file.read_text())['reaped'] for file in (base/folder/'check').glob('*-process.json'))
    verified.append(result)
# Ordinary page exposure is a separate setup action, not an injected fixture state.
expose=read('expose-list/check/result.json')
assert expose['status']=='NORMAL_PAGE_EXPOSED_NESTED_LIST' and expose['heldTouches']==0
assert expose['afterPage']>expose['beforePage'] and expose['listOffset']==0
assert not any(device['udid']=='3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463' for devices in read('stopped/stdout')['devices'].values() for device in devices)
wrappers=[json.loads(file.read_text()) for file in base.glob('*/result.json')]
assert all(w['reaped'] and w['stopReason'] is None for w in wrappers)
samples=[json.loads(line) for file in base.glob('*/resources.jsonl') for line in file.read_text().splitlines()]
assert all(row['resourceSource']=='publicLibproc' for row in samples)
result=dict(date='2026-10-21',status='OUTER270_REMAINING_SIX_NATIVE_PASSED',wireVersion=21,
    candidatePins=len(manifest['dependencies']),toolPins=len(manifest['tools']),cases=verified,
    heldTouchesAtEnd=0,productChanges=False,securityScan='UNVERIFIED',pushed=False,
    peaks={group:dict(footprintGiB=max(row[group]['footprintGiB'] for row in samples),cpuPercent=max(row[group]['cpuPercent'] for row in samples)) for group in ['app','simulator','command']},
    finalResources=read('stopped/result.json')['last'],thresholdStops=0)
(base/'main-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
