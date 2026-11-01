#!/usr/bin/env python3
"""Preflight is read-only; start and driver are explicitly live operations for the agreed slot."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import time
from probe import ROOT, RUN, Client, bounded, driver_request, record

PRODUCTS=ROOT/'build/DerivedData/Build/Products'
APP=PRODUCTS/'Debug/ProbeHost.app'

def preflight():
    checks={
        'hostBuilt':(APP/'Contents/MacOS/ProbeHost').exists(),
        'visionBuilt':(PRODUCTS/'Debug-xros/ProbeViewer.app').exists() or (ROOT/'build/DeviceData/Build/Products/Debug-xros/ProbeViewer.app').exists(),
        'fixtureBuilt':(PRODUCTS/'Debug-iphonesimulator/ProbeFixture.app').exists(),
        'fixtureTestsBuilt':any('ProbeFixtureTests' in str(plistlib.loads(p.read_bytes())) for p in PRODUCTS.glob('ProbeFixture_*.xctestrun')),
        'tlsIdentityPrepared':(RUN/'identity.p12').exists(),
        'appiumInstalled':(ROOT/'tooling/node_modules/.bin/appium').exists(),
        'wdaPrebuilt':bool(list((ROOT/'build/wda-derived/Build/Products').glob('*.xctestrun'))),
    }
    result=subprocess.run(['codesign','-dv',str(APP)],capture_output=True,text=True)
    checks['hostHasSigningAuthority']=result.returncode==0 and 'Authority=' in result.stderr
    versions={}
    for name,command in [('macOS',['sw_vers','-productVersion']),('Xcode',['xcodebuild','-version']),('node',['node','--version'])]:
        versions[name]=subprocess.check_output(command,text=True).strip()
    return {'prepared':checks,'versions':versions,'liveValidation':'See timestamped case results; preflight does not execute live checks',
            'slotSetup':['Sign Mac host before granting TCC permissions','Deploy ProbeViewer to physical Vision Pro',
                         'Agree duration or manual stop, LAN address, target windows and disposable simulator UDID',
                         'Grant capture / Accessibility / local network as needed during setup'],
            'note':'This preflight call does not enumerate windows, capture, request permissions, or launch devices. Historical live results are separate.'}

def cleanup_driver(since):
    events=RUN/'orchestrator.jsonl'
    if not events.exists(): return
    for line in events.read_text().splitlines():
        try:
            e=json.loads(line)
            if e.get('event')!='appium-session' or e.get('at',0)<since: continue
            driver_request(e['url'],'DELETE','/session/'+e['session'],timeout=1)
            record('appium-session-cleanup',session=e['session'],result='deleted')
        except Exception:
            # Already deleted, expired, or unreachable; don't touch unrelated sessions/devices.
            pass

def main():
    p=argparse.ArgumentParser(description=__doc__)
    sub=p.add_subparsers(dest='action',required=True)
    sub.add_parser('preflight')
    q=sub.add_parser('start'); q.add_argument('--seconds',type=int,default=900); q.add_argument('--until-stopped',action='store_true'); q.add_argument('--lan',action='store_true')
    q=sub.add_parser('driver'); q.add_argument('--seconds',type=int,default=600)
    q=sub.add_parser('result'); q.add_argument('case'); q.add_argument('outcome',choices=['passed','failed','blocked','untested','inconclusive']); q.add_argument('notes')
    sub.add_parser('report')
    a=p.parse_args()
    if a.action=='preflight': print(json.dumps(preflight(),indent=2)); return
    RUN.mkdir(mode=0o700,parents=True,exist_ok=True); RUN.chmod(0o700)
    if a.action=='result':
        c=Client(RUN/'connection.json') if (RUN/'connection.json').exists() else None
        from probe import safe_status
        record('case-result',case=a.case,outcome=a.outcome,notes=a.notes,status=safe_status(c) if c else {'host':'offline'})
        print('Recorded'); return
    if a.action=='report':
        events=[]
        for path in sorted(RUN.glob('*.jsonl')):
            for line in path.read_text().splitlines():
                try: events.append(json.loads(line))
                except json.JSONDecodeError: pass
        report={'generated':time.time(),'preflight':preflight(),'cases':[e for e in events if e.get('event')=='case-result'],
                'logs':[p.name for p in RUN.glob('*.jsonl')],
                'evidenceWarning':'A case note is not automatic proof. Correlate timestamps, desktop state, screenshots and xcresult; mixed lock intervals are inconclusive.'}
        (RUN/'report.json').write_text(json.dumps(report,indent=2)); print(json.dumps(report,indent=2)); return
    if not 30<=a.seconds<=7200: raise ValueError('Duration must be 30–7200 seconds')
    if a.action=='start':
        if a.until_stopped: a.seconds=0
        if (RUN/'connection.json').exists(): raise RuntimeError('A connection file already exists. Inspect/stop its owner before starting another host.')
        (RUN/'manifest.json').write_text(json.dumps(preflight(),indent=2))
        command=[str(APP/'Contents/MacOS/ProbeHost'),'--run-dir',str(RUN),'--serve','--seconds',str(a.seconds)]
        if a.lan: command+=['--lan']
        print('Starting live host. Stop with probe.py stop or the host Stop button. '+('No automatic session cutoff.' if a.until_stopped else 'Outer process deadline is also enforced.'),flush=True)
        try: bounded(command,float('inf') if a.until_stopped else a.seconds+2,RUN/'host.log')
        except TimeoutError: print('Slot process deadline reached; owned host process stopped.')
    else:
        c=Client(RUN/'connection.json'); seconds,_=c.budget(a.seconds)
        env=os.environ.copy(); env.pop('APPIUM_HOME',None) # project-local dependencies, per Appium docs
        command=[str(ROOT/'tooling/node_modules/.bin/appium'),'--address','127.0.0.1','--port','4727','--use-drivers','xcuitest','--log-timestamp']
        print('Starting isolated loopback Appium. No device session is created until probe.py appium --method attach.',flush=True)
        # bounded() stops only its own process group. Vendor device-side cleanup remains a live acceptance check.
        started=time.time()
        try: bounded(command,seconds,RUN/'appium.log',c,cwd=ROOT/'tooling',env=env,before_stop=lambda:cleanup_driver(started))
        finally: record('driver-stopped',note='Verify owned WDA runner is stopped; no unrelated simulators touched')

if __name__=='__main__':
    try: main()
    except KeyboardInterrupt: sys.exit(130)
    except Exception as error: print(str(error),file=sys.stderr); sys.exit(1)
