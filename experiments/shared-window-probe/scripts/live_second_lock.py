"""Live follow-up: continuous device video, cold interaction, and prebuilt XCTest under lock."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid
from probe import Client, ROOT, RUN, driver_request, record

c=Client(RUN/'connection.json'); targets=json.loads((RUN/'targets.json').read_text())
udid=json.loads((RUN/'disposable-simulator.json').read_text())['udid'];url='http://127.0.0.1:4727'
def sid():
    r=json.loads((RUN/'wda-attach.json').read_text());return r.get('sessionId') or r['value']['sessionId']
def req(s,method,path,body=None): return driver_request(url,method,'/session/'+s+path,body)
def outcome(name,before,passed,notes):
    after=c.status();same=before['desktop']['state']=='locked' and after['desktop']['state']=='locked' and before['generation']==after['generation']
    result=('passed' if passed else 'failed') if same else 'inconclusive'
    record('case-result',case=name,outcome=result,notes=notes,before=before,after=after)
    print(name,result,notes,flush=True)
def runner():
    r=subprocess.run(['xcrun','simctl','spawn',udid,'launchctl','list'],capture_output=True,text=True,timeout=10)
    return [line for line in r.stdout.splitlines() if 'WebDriverAgentRunner' in line]
def start_wda():
    r=subprocess.run([sys.executable,str(ROOT/'scripts/probe.py'),'appium','--udid',udid,'--method','attach'],capture_output=True,text=True,timeout=75)
    if r.returncode: raise RuntimeError(r.stderr[:2000])
    (RUN/'wda-attach.json').write_text(r.stdout);return sid()
def stream(s):
    req(s,'POST','/appium/settings',{'settings':{'mjpegServerFramerate':15,'mjpegScalingFactor':60,'mjpegServerScreenshotQuality':25}})
    c.command('deviceMJPEG',target=targets['device'],url='http://127.0.0.1:9117')
def rate(name):
    before=c.status();a=next(t for t in before['targets'] if t['id']==targets['device']);now=time.monotonic();time.sleep(5)
    b=next(t for t in c.status()['targets'] if t['id']==targets['device']);dt=time.monotonic()-now
    fps=(b['frames']-a['frames'])/dt;mbps=(b['bytes']-a['bytes'])*8/dt/1e6
    outcome(name,before,b['state']=='device_mjpeg' and fps>5,f'{fps:.2f} fps, {mbps:.2f} Mbps at the host relay; headset feedback separate')

s=sid();print('READY: waiting for second user-triggered lock',flush=True)
deadline=time.monotonic()+600;last=0
while time.monotonic()<deadline:
    state=c.status();record('second-lock-watch',status=state)
    if state['desktop']['state']=='locked':break
    if time.monotonic()-last>10: req(s,'GET','/source');last=time.monotonic()
    time.sleep(.5)
else:raise RuntimeError('No lock observed')
rate('locked-continuous-jpeg-warm')
before=c.status();old=runner();req(s,'DELETE','')
termination=subprocess.run(['xcrun','simctl','terminate',udid,'com.facebook.WebDriverAgentRunner.xctrunner'],capture_output=True,text=True,timeout=15)
s=start_wda();new=runner();record('cold-runner-processes',old=old,new=new,termination=termination.returncode)
outcome('locked-cold-wda-second-start',before,bool(new) and old!=new,'Old/new WDA runner process identities saved')
stream(s)
before=c.status();req(s,'POST','/execute/sync',{'script':'mobile: activateApp','args':[{'bundleId':'com.slopzooka.probe.fixture'}]})
def find(name): return next(iter(req(s,'POST','/element',{'using':'accessibility id','value':name})['value'].values()))
toggle=find('setting');req(s,'POST','/element/'+toggle+'/click',{})
field=find('draft');req(s,'POST','/element/'+field+'/click',{});req(s,'POST','/element/'+field+'/clear',{})
nonce='locked-fast-'+uuid.uuid4().hex[:8];req(s,'POST','/element/'+field+'/value',{'text':nonce,'value':list(nonce)})
source=req(s,'GET','/source')['value'];(RUN/'locked-cold-input.xml').write_text(source)
(RUN/'locked-cold-input.png').write_bytes(base64.b64decode(req(s,'GET','/screenshot')['value']))
outcome('locked-cold-wda-input',before,nonce in source,'Typed '+nonce+' and changed appearance; AX and screenshot saved')
rate('locked-continuous-jpeg-cold')

req(s,'DELETE','');subprocess.run(['xcrun','simctl','terminate',udid,'com.facebook.WebDriverAgentRunner.xctrunner'],capture_output=True,timeout=10)
before=c.status();print('Running standalone prebuilt XCTest while locked',flush=True)
r=subprocess.run([sys.executable,str(ROOT/'scripts/probe.py'),'ui-tests','--udid',udid,'--seconds','65','--only-testing','ProbeFixtureTests/FixtureTests/testSettingsInteractionAndEvidence'],capture_output=True,text=True,timeout=75)
(RUN/'locked-xctest-command.log').write_text(r.stdout+'\n'+r.stderr)
outcome('locked-prebuilt-xctest',before,r.returncode==0,'See locked-xctest-command.log and referenced xcresult; exit '+str(r.returncode))
try:
    s=start_wda();stream(s)
    print('Continuous device stream restored',flush=True)
except Exception as error: print('Restore failed:',error,flush=True)
print('DONE: second locked trial finished; user can unlock',flush=True)
