#!/usr/bin/env python3
"""Check saved outer90 nested-scroll evidence without simulator input."""
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
for pin in manifest['dependencies']+manifest['fixture']+manifest['tools']:
    assert digest(base/pin['copy'])==pin['sha256'],pin['copy']
    if a.current:assert digest(Path(pin['path']))==pin['sha256'],pin['path']
spec=importlib.util.spec_from_file_location('complete',base/'verify-complete.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
verified=[]
for case in ['nested-up','nested-down']:
    folder='outer90-'+case
    wrapper,result=read(folder+'/result.json'),read(folder+'/check/result.json')
    assert wrapper['exitCode']==0 and wrapper['reaped'] and wrapper['stopReason'] is None
    assert result['result']=='PASS' and result['context']['rotationDegrees']==90
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
# The first original-device setup remains failed and its safety record is preserved.
failed=read('turn90/stdout');rejected=read('setup/description-stdout')
assert failed['outcome']=='failedNoReplay' and failed['rotation']['failure']['delivery']=='uncertain'
assert failed['quarantine']['persisted'] and failed['enqueuedEventCount']==0
assert rejected['outcome']=='rejectedBeforeInput' and rejected['ax']['failure']=='ownershipRejected' and rejected['enqueuedEventCount']==0
quarantine=read('original-quarantine.json');provenance=read('original-quarantine-provenance.json')
assert quarantine['reason']=='uncertainRotationDelivery' and quarantine['simulatorUDID']=='3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463'
assert digest(base/'original-quarantine.json')==provenance['sha256']
assert read('turn90/result.json')['exitCode']==read('setup/result.json')['exitCode']==1
assert read('replacement-turn90/result.json')['exitCode']==0
# Check the ordinary page swipe from actual state and its recorded endpoints.
page_before,page_after=read('expose-list/check/state-before.json'),read('expose-list/check/state-after.json')
geometry=read('expose-list/check/geometry.json')
assert page_before['pageOffsetY']==0 and page_after['pageOffsetY']==173 and page_after['listOffsetY']==0
assert page_after['activeWindowTouches']==0
for key in ['slider','switchOn','text','textFocused','listOffsetY','pinchScale','rotationRadians','panX','panY']:
    assert page_before[key]==page_after[key]
trace=m.suffix(page_before,page_after,'windowTouchTrace','windowTraceDropped')
assert len({row['contactID'] for row in trace})==1
assert trace[0]['phase']=='windowTouchBegan' and trace[-1]['phase']=='windowTouchEnded'
assert all(row['phase']=='windowTouchMoved' for row in trace[1:-1])
assert m.near((trace[0]['x'],trace[0]['y']),geometry['start']) and m.near((trace[-1]['x'],trace[-1]['y']),geometry['end'])
assert m.suffix(page_before,page_after,'recognizerTrace','recognizerTraceDropped')==[]
assert verified[0]['before']==0 and verified[0]['after']==verified[1]['before']==70 and verified[1]['after']==0
assert all(result['pid']==9100 and result['context']['bootIdentity']=='8436:1792584942:96752' for result in verified)
assert not any(device['udid'] in ['1DF98D02-3F41-4696-A99F-42DBD4369A73','3D5E257E-DD8C-4B6F-93EB-AFAF1FDDC463'] for devices in read('stopped/stdout')['devices'].values() for device in devices)
wrappers=[json.loads(file.read_text()) for file in base.glob('*/result.json')]
assert all(w['reaped'] and w['stopReason'] is None for w in wrappers)
assert all(w['exitCode']==0 for w in wrappers if w['pid'] not in [read('turn90/result.json')['pid'],read('setup/result.json')['pid']])
resource_files=list(base.glob('*/resources.jsonl'))+[base.parent/'nested-preflight/resources.jsonl']
samples=[json.loads(line) for file in resource_files for line in file.read_text().splitlines()]
assert all(row['resourceSource']=='publicLibproc' for row in samples)
result=dict(date='2026-10-21',status='OUTER90_NESTED_TWO_NATIVE_PASSED',wireVersion=21,
    candidatePins=len(manifest['dependencies']),toolPins=len(manifest['tools']),fixturePins=len(manifest['fixture']),cases=verified,
    heldTouchesAtEnd=0,productChanges=False,securityScan='UNVERIFIED',pushed=False,
    peaks={group:dict(footprintGiB=max(row[group]['footprintGiB'] for row in samples),cpuPercent=max(row[group]['cpuPercent'] for row in samples)) for group in ['app','simulator','command']},
    finalResources=read('stopped/result.json')['last'],thresholdStops=0)
(base/'main-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
