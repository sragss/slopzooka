"""Live session only: restore explicitly chosen fixture targets and connect the headset."""
import hashlib
import http.client
import json
import os
import ssl
import struct
import subprocess
from pathlib import Path
from probe import Client, RUN, record

c=Client(RUN/'connection.json')
windows=c.request('GET','/windows')['windows']
targets={}
for key,app,title in [('native','ProbeHost','Probe Native Fixture'),('sim-window','Simulator','SlopZooka sharing probe'),('browser','Google Chrome','Shared window probe · browser fixture')]:
    matches=[w for w in windows if w['app']==app and w['title']==title]
    if len(matches)!=1: raise RuntimeError(f'Cannot uniquely resolve {key}')
    targets[key]=c.command('share',windowID=matches[0]['windowID'])['target']
udid=json.loads((RUN/'disposable-simulator.json').read_text())['udid']
targets['device']=c.command('attachSimulator',udid=udid)['target']
device=next(t for t in c.status()['targets'] if t['id']==targets['device'])
if device['state']!='device_mjpeg': c.command('deviceStream',target=targets['device'])
(RUN/'targets.json').write_text(json.dumps(targets))

config=json.loads((RUN/'connection.json').read_text())
def connection():
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);ctx.check_hostname=False;ctx.verify_mode=ssl.CERT_NONE
    h=http.client.HTTPSConnection('127.0.0.1',config['port'],context=ctx,timeout=5);h.connect()
    if hashlib.sha256(h.sock.getpeercert(binary_form=True)).hexdigest()!=config['fingerprint']: raise RuntimeError('pin mismatch')
    return h

for i in range(20):
    h=connection();h.request('GET','/stream/removed-target',headers={'Authorization':'Bearer '+config['token']})
    r=h.getresponse();r.read();assert r.status==404;h.close()
record('case-result',case='stale-stream-reconnect',outcome='passed',notes='20 obsolete target requests rejected with 404; status remains reachable')
for kind in ['native','device']:
    h=connection();h.request('GET','/stream/'+targets[kind],headers={'Authorization':'Bearer '+config['token']});r=h.getresponse();assert r.status==200
    packets=[]
    expected={'h264'} if kind=='native' else {'png','jpeg'}
    for _ in range(20):
        raw=r.read(8);assert len(raw)==8
        meta_length,payload_length=struct.unpack('>II',raw);assert meta_length<65537 and payload_length<=8*1024*1024
        meta=json.loads(r.read(meta_length));payload=r.read(payload_length);assert len(payload)==payload_length
        packets.append(meta['kind'])
        if expected.intersection(packets): break
    h.close();print(kind,'received',packets,flush=True)
    assert expected.intersection(packets)
    record('case-result',case='local-tls-'+kind,outcome='passed',notes=str(packets))
print('Network after connection cleanup:',c.status()['network'],flush=True)

config['host']='192.168.1.4';config.pop('pid',None)
env=os.environ.copy();env['DEVICECTL_CHILD_SLZ_PROBE_CONNECTION']=json.dumps(config);env['DEVICECTL_CHILD_SLZ_PROBE_AUTO_OPEN']='all'
subprocess.run(['xcrun','devicectl','device','process','launch','--terminate-existing','--device','FFA7104B-5972-57E0-B392-05D7A5976599','com.slopzooka.probe.viewer'],env=env,check=True)
print('Targets ready:',targets)
