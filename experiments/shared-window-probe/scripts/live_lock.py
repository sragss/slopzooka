"""Observe a user-triggered lock, then exercise only the dedicated probe simulator."""
import base64
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path
from probe import Client, ROOT, RUN, driver_request, record

c=Client(RUN/'connection.json')
targets=json.loads((RUN/'targets.json').read_text())
udid=json.loads((RUN/'disposable-simulator.json').read_text())['udid']
url='http://127.0.0.1:4727'
def session_id():
    r=json.loads((RUN/'wda-attach.json').read_text());return r.get('sessionId') or r['value']['sessionId']
def request(session,method,route,body=None,timeout=15):
    return driver_request(url,method,'/session/'+session+route,body,timeout)
def case(name,passed,before,notes):
    after=c.status()
    locked=before['desktop']['state']=='locked' and after['desktop']['state']=='locked' and before['generation']==after['generation']
    outcome=('passed' if passed else 'failed') if locked else 'inconclusive'
    record('case-result',case=name,outcome=outcome,notes=notes,before=before,after=after)
    print(name,outcome,notes,flush=True)
def interact(session,label):
    before=c.status()
    request(session,'POST','/execute/sync',{'script':'mobile: activateApp','args':[{'bundleId':'com.slopzooka.probe.fixture'}]})
    source=request(session,'GET','/source')['value']
    import re
    match=re.search(r'Count: (\d+)',source); old=int(match[1]) if match else -1
    result=request(session,'POST','/element',{'using':'accessibility id','value':'increment'})
    element=next(iter(result['value'].values()));request(session,'POST','/element/'+element+'/click',{})
    source=request(session,'GET','/source')['value'];(RUN/(label+'.xml')).write_text(source)
    shot=request(session,'GET','/screenshot')['value'];(RUN/(label+'-wda.png')).write_bytes(base64.b64decode(shot))
    (RUN/(label+'-simctl.png')).write_bytes(c.request('GET','/snapshot/'+targets['device']))
    case(label,old>=0 and f'Count: {old+1}' in source,before,f'Count {old} → {old+1}; AX and two independent PNGs saved')

s=session_id()
request(s,'POST','/execute/sync',{'script':'mobile: activateApp','args':[{'bundleId':'com.slopzooka.probe.fixture'}]})
print('READY: waiting for the user to lock the Mac',flush=True)
start=time.monotonic();last_keepalive=0
while time.monotonic()-start<600:
    state=c.status()
    record('lock-watch',status=state)
    if state['desktop']['state']=='locked': break
    if time.monotonic()-last_keepalive>10:
        request(s,'GET','/source');last_keepalive=time.monotonic()
    time.sleep(.5)
else: raise RuntimeError('No lock observed; no locked tests ran')

record('locked-trial-start',status=state)
print('LOCK OBSERVED: testing blocked native control and simulator fallback',flush=True)
before=c.status()
try:
    c.command('resize',target=targets['native'],width=999,height=777)
    blocked=False
except RuntimeError as error: blocked='desktop_locked' in str(error)
case('locked-native-input-rejected',blocked,before,'Resize must reject before touching AX')
before=c.status()
try:
    c.request('GET','/snapshot/'+targets['native']);blocked=False
except RuntimeError as error: blocked='desktop_locked' in str(error)
case('locked-native-capture-rejected',blocked,before,'Desktop screenshot must reject')

before=c.status();nonce='locked-'+uuid.uuid4().hex[:8]
subprocess.run(['xcrun','simctl','openurl',udid,'slz-probe://nonce?value='+nonce],check=True,timeout=15)
(RUN/'locked-nonce.png').write_bytes(c.request('GET','/snapshot/'+targets['device']))
source=request(s,'GET','/source')['value']
case('locked-device-freshness',nonce in source,before,'Expected visible nonce '+nonce+'; saved locked-nonce.png')
interact(s,'locked-warm-wda')

before=c.status()
request(s,'DELETE','')
subprocess.run(['xcrun','simctl','terminate',udid,'com.facebook.WebDriverAgentRunner.xctrunner'],capture_output=True,timeout=15)
result=subprocess.run([sys.executable,str(ROOT/'scripts/probe.py'),'appium','--udid',udid,'--method','attach'],capture_output=True,text=True,timeout=90)
if result.returncode:
    case('locked-cold-wda',False,before,result.stderr[:1500])
else:
    (RUN/'wda-attach.json').write_text(result.stdout)
    case('locked-cold-wda',True,before,'Previous WDA session deleted/runner termination attempted; new session created while locked; inspect startup log')
    interact(session_id(),'locked-cold-wda-interaction')
print('DONE: locked tests finished. User can unlock.',flush=True)
