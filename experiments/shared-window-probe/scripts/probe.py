#!/usr/bin/env python3
"""Control the explicitly armed prototype; no implicit app or simulator startup."""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import plistlib
import signal
import ssl
import subprocess
import sys
import time
import urllib.parse
import uuid
ROOT=Path(__file__).resolve().parents[1]
RUN=ROOT/'build/run'

class Client:
    def __init__(self,path): self.config=json.loads(Path(path).read_text())
    def request(self,method,path,body=None,timeout=15):
        c=self.config
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname=False; context.verify_mode=ssl.CERT_NONE
        conn=http.client.HTTPSConnection(c['host'],int(c['port']),timeout=timeout,context=context)
        try:
            conn.connect()
            # Pin is verified before any Authorization header is sent.
            if hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()!=c['fingerprint'].lower():
                raise RuntimeError('TLS pin mismatch; credentials not sent')
            conn.request(method,path,json.dumps(body).encode() if body is not None else None,
                         {'Authorization':'Bearer '+c['token'],'Content-Type':'application/json'})
            response=conn.getresponse(); data=response.read(16*1024*1024+1)
            if len(data)>16*1024*1024: raise RuntimeError('Response too large')
            if response.status!=200: raise RuntimeError(data.decode(errors='replace'))
            return data if response.getheader('Content-Type')=='image/png' else json.loads(data)
        finally: conn.close()
    def status(self): return self.request('GET','/status')
    def budget(self,requested=120):
        s=self.status(); remaining=float('inf') if s.get('untilStopped') else float(s.get('remainingSeconds',0))
        if not s.get('armed') or remaining<=5: raise RuntimeError('Unarmed or cleanup reserve reached')
        return min(requested,remaining-5),s
    def command(self,action,**fields):
        _,s=self.budget(); fields.setdefault('generation',s['generation'])
        return self.request('POST','/command',dict(action=action,**fields))

def record(event,**fields):
    RUN.mkdir(mode=0o700,parents=True,exist_ok=True)
    with (RUN/'orchestrator.jsonl').open('a') as f: f.write(json.dumps(dict(event=event,at=time.time(),monotonic=time.monotonic(),**fields))+'\n')

def safe_status(client):
    try: return client.status()
    except Exception as error: return {'unreachable':str(error)}

def bounded(command,timeout,log,client=None,cwd=None,env=None,before_stop=None):
    log=Path(log); log.parent.mkdir(parents=True,exist_ok=True)
    with log.open('wb') as output:
        p=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True,cwd=cwd,env=env)
        deadline=time.monotonic()+timeout
        wall_deadline=time.time()+timeout
        try:
            next_check=0
            while p.poll() is None:
                if time.monotonic()>=deadline or time.time()>=wall_deadline: raise TimeoutError('Command exceeded operation/slot budget')
                if client and time.monotonic()>=next_check: client.budget(); next_check=time.monotonic()+1
                time.sleep(.1)
            if p.returncode: raise RuntimeError(f'Exit {p.returncode}; see {log}')
        finally:
            if before_stop:
                try: before_stop()
                except Exception: pass
            if p.poll() is None:
                os.killpg(p.pid,signal.SIGTERM)
                try: p.wait(timeout=2)
                except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait(timeout=2)

def driver_request(url,method,path,body=None,timeout=15):
    u=urllib.parse.urlsplit(url)
    if u.scheme!='http' or u.hostname not in ('127.0.0.1','localhost','::1') or u.username or u.query or u.fragment or u.path not in ('','/'):
        raise ValueError('Use an explicit loopback Appium URL')
    c=http.client.HTTPConnection(u.hostname,u.port or 4727,timeout=timeout)
    try:
        c.request(method,path,json.dumps(body) if body is not None else None,{'Content-Type':'application/json'})
        r=c.getresponse(); raw=r.read(16*1024*1024+1)
        if len(raw)>16*1024*1024: raise RuntimeError('Driver response too large')
        value=json.loads(raw)
        if r.status>=400 or isinstance(value.get('value'),dict) and value['value'].get('error'): raise RuntimeError(json.dumps(value))
        return value
    finally: c.close()

def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('--connection',default=str(RUN/'connection.json'))
    sub=p.add_subparsers(dest='action',required=True)
    for name in ('status','windows','stop'): sub.add_parser(name)
    q=sub.add_parser('share'); q.add_argument('window_id',type=int)
    q=sub.add_parser('command'); q.add_argument('json')
    q=sub.add_parser('snapshot'); q.add_argument('target'); q.add_argument('output',type=Path)
    q=sub.add_parser('attach-simulator'); q.add_argument('udid')
    q=sub.add_parser('watch'); q.add_argument('--seconds',type=float,default=60)
    q=sub.add_parser('ui-tests'); q.add_argument('--udid',required=True); q.add_argument('--xctestrun',type=Path); q.add_argument('--only-testing'); q.add_argument('--seconds',type=float,default=120)
    q=sub.add_parser('appium'); q.add_argument('--url',default='http://127.0.0.1:4727'); q.add_argument('--udid',required=True); q.add_argument('--session'); q.add_argument('--bundle-id',default='com.slopzooka.probe.fixture'); q.add_argument('--method',required=True,choices=['attach','detach','source','screenshot','find','click','type','swipe']); q.add_argument('--value'); q.add_argument('--element'); q.add_argument('--output',type=Path)
    a=p.parse_args(); c=Client(a.connection)
    if a.action=='status': result=c.status()
    elif a.action=='windows': result=c.request('GET','/windows')
    elif a.action=='stop':
        try: result=c.request('POST','/command',{'action':'stop'})
        except (http.client.RemoteDisconnected,ConnectionError): result={'stopRequested':True,'connectionClosed':True}
    elif a.action=='share': result=c.command('share',windowID=a.window_id)
    elif a.action=='command':
        values=json.loads(a.json); action=values.pop('action'); result=c.command(action,**values)
    elif a.action=='attach-simulator': uuid.UUID(a.udid); result=c.command('attachSimulator',udid=a.udid)
    elif a.action=='snapshot':
        image=c.request('GET','/snapshot/'+urllib.parse.quote(a.target,safe=''))
        if not isinstance(image,bytes): raise RuntimeError('Not an image')
        a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_bytes(image)
        result={'file':str(a.output),'bytes':len(image),'freshness':'Verify visible state/nonce'}
    elif a.action=='watch':
        seconds,_=c.budget(a.seconds); deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            s=c.status(); record('status',status=s)
            print(json.dumps({'desktop':s['desktop'],'generation':s['generation'],'remaining':s['remainingSeconds']}),flush=True)
            if not s.get('armed'): break
            time.sleep(.5)
        result={'log':str(RUN/'orchestrator.jsonl')}
    elif a.action=='ui-tests':
        uuid.UUID(a.udid); seconds,before=c.budget(a.seconds)
        paths=[p for p in (ROOT/'build/DerivedData/Build/Products').glob('ProbeFixture_*.xctestrun')
               if 'ProbeFixtureTests' in str(plistlib.loads(p.read_bytes()))]
        spec=a.xctestrun or (paths[0] if len(paths)==1 else None)
        if not spec or not spec.exists(): raise ValueError('Supply the prebuilt --xctestrun')
        folder=RUN/('ui-test-'+str(uuid.uuid4())); folder.mkdir()
        command=['xcodebuild','test-without-building','-xctestrun',str(spec),'-destination','platform=iOS Simulator,id='+a.udid,
                 '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1','-destination-timeout','15',
                 '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','60','-maximum-test-execution-time-allowance','90',
                 '-resultBundlePath',str(folder/'result.xcresult')]
        if a.only_testing: command+=['-only-testing:'+a.only_testing]
        record('ui-test-start',udid=a.udid,desktop=before['desktop'],result=str(folder))
        try: bounded(command,seconds,folder/'xcodebuild.log',c)
        finally: record('ui-test-end',result=str(folder),status=safe_status(c))
        after=c.status(); result={'result':str(folder),'desktopBefore':before['desktop'],'desktopAfter':after['desktop'],'generationUnchanged':before['generation']==after['generation']}
    else: result=appium(a,c)
    print(json.dumps(result,indent=2))

def appium(a,c):
    uuid.UUID(a.udid); seconds,before=c.budget(90)
    if a.method=='attach':
        caps={'platformName':'iOS','appium:automationName':'XCUITest','appium:udid':a.udid,'appium:bundleId':a.bundle_id,
              'appium:noReset':True,'appium:autoLaunch':False,'appium:forceAppLaunch':False,'appium:shouldTerminateApp':False,
              'appium:isHeadless':False,'appium:shutdownOtherSimulators':False,'appium:wdaLocalPort':8117,'appium:mjpegServerPort':9117,
              'appium:wdaBindingIP':'127.0.0.1','appium:wdaLaunchTimeout':45000,'appium:wdaConnectionTimeout':15000,
              'appium:wdaStartupRetries':1,'appium:newCommandTimeout':600,'appium:usePrebuiltWDA':True,
              'appium:derivedDataPath':str(ROOT/'build/wda-derived')}
        result=driver_request(a.url,'POST','/session',{'capabilities':{'alwaysMatch':caps}},seconds)
        session=result.get('sessionId') or result.get('value',{}).get('sessionId')
        if session: record('appium-session',url=a.url,session=session,udid=a.udid)
    else:
        if not a.session or not all(x.isalnum() or x in '-_' for x in a.session): raise ValueError('Supply exact session ID')
        prefix='/session/'+a.session; info=driver_request(a.url,'GET',prefix); caps=info.get('value',{}); caps=caps.get('capabilities',caps)
        if caps.get('udid',caps.get('appium:udid'))!=a.udid: raise RuntimeError('Session does not prove requested UDID')
        method,route,body='GET','/'+a.method,None
        if a.method=='detach': method,route='DELETE',''
        elif a.method=='find': method,route,body='POST','/element',{'using':'accessibility id','value':a.value}
        elif a.method in ('click','type'):
            if not a.element: raise ValueError('Supply element from a fresh find result')
            method='POST'; route='/element/'+urllib.parse.quote(a.element,safe='')+('/click' if a.method=='click' else '/value')
            body={} if a.method=='click' else {'text':a.value or '', 'value':list(a.value or '')}
        elif a.method=='swipe':
            if a.value not in ('up','down','left','right'): raise ValueError('Supply swipe direction')
            method,route,body='POST','/execute/sync',{'script':'mobile: swipe','args':[{'direction':a.value}]}
        c.budget(); result=driver_request(a.url,method,prefix+route,body,min(seconds,15))
        if a.method=='screenshot' and a.output:
            a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_bytes(base64.b64decode(result['value'],validate=True)); result={'file':str(a.output)}
    after=c.status(); record('appium',method=a.method,udid=a.udid,desktopBefore=before['desktop'],desktopAfter=after['desktop'],generationUnchanged=before['generation']==after['generation'])
    return result

if __name__=='__main__':
    try: main()
    except KeyboardInterrupt: sys.exit(130)
    except Exception as error: print(json.dumps({'error':str(error)}),file=sys.stderr); sys.exit(1)
