#!/usr/bin/env python3
"""Run one local command with bounded resource sampling and owned-child cleanup."""
import argparse, json, os, signal, subprocess, time
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--resource-probe', required=True)
parser.add_argument('--out',required=True)
parser.add_argument('--timeout',type=float,default=90)
parser.add_argument('command',nargs=argparse.REMAINDER)
args=parser.parse_args()
command=args.command[1:] if args.command[:1]==['--'] else args.command
if not command or args.timeout<=0: parser.error('One command and positive timeout required')
folder=Path(args.out);folder.mkdir(parents=True,exist_ok=False)
started=time.monotonic();child=None;samples=[];signals=[];reason=None;code=None
previous_rows={};previous_time=None
probe=Path(args.resource_probe).resolve()

def sample():
    global previous_rows,previous_time
    result=subprocess.run([str(probe)],capture_output=True,text=True,timeout=5,check=True)
    measured=time.monotonic()
    payload=json.loads(result.stdout)
    if payload.get('source')!='publicLibproc':raise ValueError('Unexpected resource source')
    rows=payload['rows']
    if not rows:raise ValueError('Empty process snapshot')
    if not any(r['name'] in ['ChatGPT','Codex'] for r in rows):raise ValueError('App process absent from snapshot')
    interval=measured-previous_time if previous_time is not None else 0
    for row in rows:
        previous=previous_rows.get(row['pid'])
        row['cpu']=max(0,row['cpuTimeNs']-previous['cpuTimeNs'])/1_000_000_000/interval*100 if previous is not None and previous['start']==row['start'] and interval>0 else 0
    previous_rows={r['pid']:r for r in rows};previous_time=measured
    def descendants(roots):
        members=set(roots)
        while True:
            added={r['pid'] for r in rows if r['ppid'] in members}-members
            if not added:return members
            members.update(added)
    app=descendants(r['pid'] for r in rows if r['name'] in ['ChatGPT', 'Codex'])
    sim=descendants(r['pid'] for r in rows if r['name']=='launchd_sim')
    sim.update(r['pid'] for r in rows if any(x in r['name'] for x in ['DeviceHub','SimulatorTramp','CoreSimulator','simdiskimaged']))
    owned=descendants([child.pid]) if child else set()
    def group(members):
        items=[r for r in rows if r['pid'] in members]
        return dict(footprintGiB=round(sum(r['footprintBytes'] for r in items)/1073741824,3),cpuPercent=round(sum(r['cpu'] for r in items),1),processes=len(items))
    value=dict(resourceSource='publicLibproc',elapsedSeconds=round(time.monotonic()-started,2),app=group(app),simulator=group(sim),command=group(owned))
    samples.append(value)
    with (folder/'resources.jsonl').open('a') as f:f.write(json.dumps(value)+'\n')
    return value

def stop_owned():
    if child is None or child.poll() is not None:return
    for sig,wait in [(signal.SIGINT,5),(signal.SIGTERM,5),(signal.SIGKILL,5)]:
        try:os.killpg(child.pid,sig);signals.append(sig.name)
        except ProcessLookupError:break
        try:child.wait(timeout=wait);return
        except subprocess.TimeoutExpired:pass

try:
    baseline=sample()
    if baseline['app']['footprintGiB']>=8 or baseline['simulator']['footprintGiB']>=10:
        reason='RESOURCE_LIMIT_BEFORE_LAUNCH'
    else:
        with (folder/'stdout').open('xb') as stdout,(folder/'stderr').open('xb') as stderr:
            child=subprocess.Popen(command,stdout=stdout,stderr=stderr,start_new_session=True)
            (folder/'started.json').write_text(json.dumps(dict(command=command,pid=child.pid),indent=2)+'\n')
            hot_since=None
            while True:
                try:code=child.wait(timeout=2);break
                except subprocess.TimeoutExpired:pass
                current=sample()
                high=current['app']['footprintGiB']>=8 or current['simulator']['footprintGiB']>=10 or current['command']['footprintGiB']>=4
                hot=current['simulator']['cpuPercent']>=1200 or current['command']['cpuPercent']>=400
                hot_since=(hot_since or time.monotonic()) if hot else None
                if high:reason='MEMORY_LIMIT';break
                if hot_since and time.monotonic()-hot_since>=20:reason='SUSTAINED_CPU_LIMIT';break
                if time.monotonic()-started>=args.timeout:reason='TIME_LIMIT';break
            if reason:stop_owned();code=child.poll()
except BaseException as error:
    reason='MONITOR_ERROR: '+repr(error)
    stop_owned()
    if child:code=child.poll()
finally:
    try:sample()
    except BaseException as error:
        if reason is None:reason='FINAL_MONITOR_ERROR: '+repr(error)
result=dict(command=command,pid=child.pid if child else None,exitCode=code,reaped=child is None or child.poll() is not None,stopReason=reason,signalsSent=signals,elapsedSeconds=round(time.monotonic()-started,2),sampleCount=len(samples),peaks={name:max((s[name]['footprintGiB'] for s in samples),default=0) for name in ['app','simulator','command']},last=samples[-1] if samples else None)
(folder/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
raise SystemExit(0 if reason is None and code==0 else 2)
