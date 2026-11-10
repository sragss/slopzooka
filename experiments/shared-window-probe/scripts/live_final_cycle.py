"""One observed stream cycle; keep WDA running and resume selected native targets on unlock."""
import base64,json,plistlib,subprocess,time
from probe import Client,RUN,driver_request,record
c=Client(RUN/'connection.json');targets=json.loads((RUN/'targets.json').read_text());r=json.loads((RUN/'wda-attach.json').read_text());sid=r.get('sessionId') or r['value']['sessionId'];url='http://127.0.0.1:4727'
def req(m,p,b=None):return driver_request(url,m,'/session/'+sid+p,b)
def locked():
    r=plistlib.loads(subprocess.check_output(['ioreg','-a','-l','-d','1','-w','0'],timeout=5));return (r if isinstance(r,dict) else r[0]).get('IOConsoleLocked')
print('READY for final lock',flush=True)
end=time.monotonic()+180
while time.monotonic()<end and c.status()['desktop']['state']!='locked':time.sleep(.25)
assert c.status()['desktop']['state']=='locked','No new lock observed'
before=c.status();samples=[];print('Final lock observed',flush=True)
try:
    for i in range(4):
        element=next(iter(req('POST','/element',{'using':'accessibility id','value':'increment'})['value'].values()))
        req('POST','/element/'+element+'/click',{})
        tree=req('GET','/source')['value'];(RUN/('final-cycle-source-'+str(i)+'.xml')).write_text(tree)
        record('final-cycle-input',step=i,consoleLocked=locked(),status=c.status())
        time.sleep(3)
    (RUN/'final-cycle-locked.png').write_bytes(base64.b64decode(req('GET','/screenshot')['value']))
except Exception as e:record('final-cycle-input-error',message=str(e)[:500]);print('Input error recorded',flush=True)
for _ in range(8):
    samples.append({'consoleLocked':locked(),'status':c.status()});time.sleep(1)
after=c.status();(RUN/'final-cycle-streams.json').write_text(json.dumps(samples,indent=2))
a=next(t for t in before['targets'] if t['id']==targets['device']);b=next(t for t in after['targets'] if t['id']==targets['device'])
record('case-result',case='final-cycle-device-source',outcome='passed' if all(x['consoleLocked'] is True for x in samples) and b['frames']>a['frames'] else 'inconclusive',notes='Device frames advanced '+str(b['frames']-a['frames'])+'; headset observation separate',before=before,after=after)
print('READY TO UNLOCK: continuous stream observation complete',flush=True)
end=time.monotonic()+180
while time.monotonic()<end:
    s=c.status()
    if s['desktop']['state']=='unlocked':
        for t in s['targets']:
            if t['kind']=='mac-window':c.command('resume',target=t['id'])
        record('final-cycle-resumed',status=c.status());print('Native streams resumed after unlock',flush=True);break
    time.sleep(.25)
else:print('Unlock not observed within operation wait',flush=True)
