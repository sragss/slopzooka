"""Run the selected fixture tests while recording lock separately from display availability."""
import json,plistlib,subprocess,sys,time
from probe import Client,ROOT,RUN,driver_request,record
c=Client(RUN/'connection.json');udid=json.loads((RUN/'disposable-simulator.json').read_text())['udid']
def console_locked():
    value=plistlib.loads(subprocess.check_output(['ioreg','-a','-l','-d','1','-w','0'],timeout=5))
    return (value if isinstance(value,dict) else value[0]).get('IOConsoleLocked')
def sid():
    r=json.loads((RUN/'wda-attach.json').read_text());return r.get('sessionId') or r['value']['sessionId']
assert console_locked() is True, 'This run requires a user-locked Mac'
s=sid()
try: driver_request('http://127.0.0.1:4727','DELETE','/session/'+s)
except RuntimeError: pass
subprocess.run(['xcrun','simctl','terminate',udid,'com.facebook.WebDriverAgentRunner.xctrunner'],capture_output=True,timeout=15)
before=c.status();samples=[]
with (RUN/'locked-xctest-corrected.log').open('w') as log:
    p=subprocess.Popen([sys.executable,str(ROOT/'scripts/probe.py'),'ui-tests','--udid',udid,'--seconds','120','--xctestrun',str(ROOT/'build/DerivedData/Build/Products/ProbeFixture_iphonesimulator26.2-arm64-x86_64.xctestrun')],stdout=log,stderr=subprocess.STDOUT)
    while p.poll() is None:
        sample={'at':time.time(),'consoleLocked':console_locked(),'desktop':c.status()['desktop']};samples.append(sample)
        record('xctest-lock-watch',sample=sample);time.sleep(.5)
    code=p.returncode
samples.append({'at':time.time(),'consoleLocked':console_locked(),'desktop':c.status()['desktop']})
(RUN/'locked-xctest-state.json').write_text(json.dumps(samples,indent=2))
locked=all(x['consoleLocked'] is True for x in samples)
record('case-result',case='locked-display-asleep-prebuilt-xctest-corrected',outcome=('passed' if code==0 else 'failed') if locked else 'inconclusive',notes='Corrected scheme, both fixture cases, exit '+str(code)+'; sampled IOConsoleLocked throughout; see locked-xctest-corrected.log and locked-xctest-state.json.',before=before,after=c.status())
print('XCTest finished:',code,'remained locked:',locked,flush=True)
r=subprocess.run([sys.executable,str(ROOT/'scripts/probe.py'),'appium','--udid',udid,'--method','attach'],capture_output=True,text=True,timeout=75)
if r.returncode:raise RuntimeError(r.stderr[:1000])
(RUN/'wda-attach.json').write_text(r.stdout);s=sid()
driver_request('http://127.0.0.1:4727','POST','/session/'+s+'/appium/settings',{'settings':{'mjpegServerFramerate':15,'mjpegScalingFactor':60,'mjpegServerScreenshotQuality':25}})
c.command('deviceMJPEG',target=json.loads((RUN/'targets.json').read_text())['device'],url='http://127.0.0.1:9117')
print('Device stream restored',flush=True)
