import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID, createHash } from 'node:crypto';
import { networkInterfaces } from 'node:os';
import { createInterface } from 'node:readline';
import { createRequire } from 'node:module';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const baseDir = '/tmp/slz-preview-validation';
const mac = path.join(baseDir, 'mac/SlopZooka.app');
const resources = path.join(mac, 'Contents/Resources');
const vpApp = path.join(baseDir, 'vp/Build/Products/Debug-xros/SlopZooka.app');
const device = 'FFA7104B-5972-57E0-B392-05D7A5976599';
const simulator = '761C24A5-F683-49C2-A87D-5899350E65D4';
const vpBundle = 'com.slopzooka.probe.nativepreview';
const iosBundle = 'com.slopzooka.probe.nativefixture.ios';
const smoke = process.argv.includes('--smoke');
const mcpMode = process.argv.includes('--mcp');
let mcpClient;
async function connectMCP() {
  if (mcpClient) return mcpClient;
  if (!smoke && clientID === operatorClientID) throw new Error('Pair and adopt the isolated headset before MCP commands');
  const require = createRequire(path.join(root, 'apps/mac-companion/package.json'));
  const { Client } = require('@modelcontextprotocol/client');
  const { StdioClientTransport } = require('@modelcontextprotocol/client/stdio');
  const config = path.join(run, 'mcp.private.json');
  await fs.writeFile(config, JSON.stringify({origin:base,hostId:hostID,clientId:clientID,token}), {mode:0o600});
  const candidate = new Client({name:'slz-device-operator',version:'1.0.0'});
  try {
    await candidate.connect(new StdioClientTransport({command:path.join(resources,'runtime/node'),args:[path.join(resources,'host/src/preview-mcp.mjs'),config],cwd:run,stderr:'inherit'}));
    mcpClient = candidate;
    return candidate;
  } catch (error) { await candidate.close(); throw error; }
}
async function callMCP(name, args = {}) {
  const client = await connectMCP();
  const result = await client.callTool({name,arguments:args});
  await journal('mcp.tool.completed',{tool:name,isError:result.isError===true});
  console.log(JSON.stringify({event:'mcp.result',tool:name,result}));
  return result;
}
if (!smoke && !process.argv.includes('--live')) throw new Error('Choose --smoke or --live. Live opens only disposable Mac fixtures; launch installs the headset test app.');
process.umask(0o077);
const run = await fs.mkdtemp(path.join(baseDir, smoke ? 'smoke-' : 'run-'));
const home = path.join(run, 'home');
await fs.mkdir(path.join(home, 'workspaces'), { recursive: true, mode: 0o700 });
const operatorClientID = randomUUID();
let clientID = operatorClientID;
const sessionIDs = ['preview-a', 'preview-b'];
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const journal = async (event, fields = {}) => fs.appendFile(path.join(run, 'operator.jsonl'), JSON.stringify({ at: new Date().toISOString(), event, ...fields }) + '\n');
async function until(fn, timeout = 20000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { const value = await fn(); if (value) return value; await pause(100); }
  throw new Error('Readiness timed out; inspect this run’s private logs');
}
const reservation = http.createServer();
reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
const port = reservation.address().port;
await new Promise(resolve => reservation.close(resolve));
const base = `http://127.0.0.1:${port}`;
const iface = execFileSync('/sbin/route', ['-n', 'get', 'default'], { encoding: 'utf8' }).match(/interface:\s*(\S+)/)?.[1];
const address = networkInterfaces()[iface]?.find(a => a.family === 'IPv4' && !a.internal)?.address;
if (!address) throw new Error('No LAN address on default interface');
const privateStatus = path.join(run, 'desktop.private.json');
// Observe only the existing private parent pipe in this disposable test process.
// Production binaries and protocol are unchanged. Never persist other stdout.
await fs.writeFile(path.join(run, 'pairing-tap.cjs'), `
const fs = require('node:fs');
const original = process.stdout.write.bind(process.stdout);
let pending = '';
process.stdout.write = function(chunk, ...args) {
  pending += Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk);
  if (pending.length > 65536) pending = '';
  let end;
  while ((end = pending.indexOf('\\n')) >= 0) {
    const line = pending.slice(0, end); pending = pending.slice(end + 1);
    if (line.startsWith('SLZ_DESKTOP ')) {
      try {
        const value = JSON.parse(line.slice(12));
        const target = ${JSON.stringify(privateStatus)};
        fs.writeFileSync(target + '.tmp', JSON.stringify({code:value.code, sessionSocketPath:value.sessionSocketPath, pid:process.pid, at:Date.now()}), {mode:0o600});
        fs.renameSync(target + '.tmp', target);
      } catch {}
    }
  }
  return original(chunk, ...args);
};
`);
await fs.writeFile(path.join(home, 'workspaces/index.json'), JSON.stringify([{
  workspaceId: 'preview-test', repo: { nameWithOwner: 'test/preview-test', owner: { login: 'test', avatarUrl: '' }, name: 'preview-test', isPrivate: false, defaultBranch: 'main' },
  profile: null, localCheckoutPath: run, worktreePath: run, branchName: 'preview-validation', baseRef: 'main',
  createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
}]));
await fs.writeFile(path.join(run, 'terminal.py'), `import os,json,time\nreceipt=${JSON.stringify(path.join(run, 'terminal-receipts.jsonl'))}\nprint('PREVIEW VALIDATION | PID',os.getpid(),flush=True)\nwhile True:\n try: text=input('input> ')\n except EOFError: break\n except KeyboardInterrupt: continue\n print('ACK',text,'PID',os.getpid(),flush=True)\n with open(receipt,'a') as f: f.write(json.dumps({'at':time.time(),'pid':os.getpid(),'text':text})+'\\n')\n`);
let fixtureState = { nonce: randomUUID().slice(0,8), counter:1, portrait:false, closed:false, covered:false, staticImage:false };
const stateFile = path.join(run, 'fixture.json');
async function writeFixture(change = {}) {
  fixtureState = { ...fixtureState, ...change };
  await fs.writeFile(stateFile + '.tmp', JSON.stringify(fixtureState));
  await fs.rename(stateFile + '.tmp', stateFile);
}
await writeFixture();
let child, fixture, token, hostID, iosStateFile, stopped = false;
const env = { ...process.env, SLOPZOOKA_HOME:home, SLOPZOOKA_PORT:String(port), SLOPZOOKA_HOST:smoke ? '127.0.0.1' : '0.0.0.0',
  SLOPZOOKA_PORTLESS:'0', PORTLESS_STATE_DIR:path.join(home,'portless'), SLOPZOOKA_DESKTOP:'1',
  SLOPZOOKA_BONJOUR_NAME:'Slz Preview Test', SLOPZOOKA_DIRECT:smoke ? '0' : '1', SLOPZOOKA_WINDOW_PREVIEWS:smoke ? '0' : '1',
  SHELL:'/bin/sh', SLOPZOOKA_CODEX_COMMAND:`/usr/bin/python3 -u ${run}/terminal.py`, NODE_OPTIONS:`--require=${path.join(run,'pairing-tap.cjs')}` };
const readPrivateStatus = async () => JSON.parse(await fs.readFile(privateStatus, 'utf8'));
async function api(route, method = 'GET', body) {
  const response = await fetch(base + route, { method, headers: { ...(token ? {Authorization:`Bearer ${token}`} : {}), 'Content-Type':'application/json', 'X-SlopZooka-Client-ID':clientID }, body:body === undefined ? undefined : JSON.stringify(body), signal:AbortSignal.timeout(12000) });
  const value = await response.json();
  if (!response.ok) throw new Error(`${route}: ${response.status} ${value.error ?? ''}`);
  return value;
}
async function layoutAdd(records) {
  for (let attempt=0; attempt<3; attempt++) {
    const layout = await api('/api/window-layout');
    const byID = new Map(layout.windows.map(r=>[r.id,r]));
    for (const record of records) byID.set(record.id,record);
    try { return await api('/api/window-layout','PUT',{ ...layout, windows:[...byID.values()] }); }
    catch (error) { if (!error.message.includes(': 409') || attempt===2) throw error; }
  }
}
async function status() {
  const [sessions, health, layout] = await Promise.all([api('/api/sessions'),api('/health'),api('/api/window-layout')]);
  const value = { run, address:`${address}:${port}`, nonce:fixtureState.nonce, counter:fixtureState.counter,
    companionInstanceId:health.companionInstanceId, serviceInstanceId:sessions.serviceInstanceId,
    directAvailable:health.transport.direct, sessions:sessions.sessions.map(s=>({id:s.id,status:s.status})), windows:layout.windows };
  await journal('status',value); console.log(JSON.stringify(value)); return value;
}
async function pulse() {
  await writeFixture({nonce:randomUUID().slice(0,8),counter:fixtureState.counter+1});
  if (!smoke) {
    await fs.writeFile(iosStateFile+'.tmp',JSON.stringify({nonce:fixtureState.nonce}));
    await fs.rename(iosStateFile+'.tmp',iosStateFile);
  }
  for (const id of sessionIDs) await api(`/api/sessions/${id}/input`,'POST',{text:`${id}-${fixtureState.nonce}`,commandId:randomUUID(),sendReturn:true});
  await until(async()=>{const text=await fs.readFile(path.join(run,'terminal-receipts.jsonl'),'utf8').catch(()=> '');return sessionIDs.every(id=>text.includes(`${id}-${fixtureState.nonce}`));});
  await journal('pulse',{nonce:fixtureState.nonce,counter:fixtureState.counter});
  console.log(JSON.stringify({event:'pulse',nonce:fixtureState.nonce,counter:fixtureState.counter,ptyACKs:2,headsetPresentationNotYetConfirmed:true}));
}
async function sources() {
  const catalog = (await api('/api/frontends')).windows;
  if (!catalog || catalog.state!=='ready') throw new Error(`Capture catalog: ${catalog?.state ?? 'disabled'}`);
  const native = catalog.sources.filter(s=>s.id.split(':').at(-2)===String(fixture.pid) && s.title==='Slz Native Preview Fixture');
  const sim = catalog.sources.filter(s=>s.application==='Simulator' && (s.title.includes('Slz Native Preview Validation') || s.title.includes('iPhone 16e')));
  if (native.length!==1 || sim.length!==1) throw new Error(`Expected one owned source each: native=${native.length}, simulator=${sim.length}; inspect candidates before selection`);
  return [native[0],sim[0]];
}
async function openPreviews() {
  const selected = await sources();
  for (const source of selected) await api('/api/window-previews/open','POST',{id:source.id});
  await layoutAdd(selected.map(source=>({id:`${hostID}:${source.id}`,kind:'preview',targetID:source.id})));
  await journal('previews.requested',{sourceIDs:selected.map(s=>s.id).join(',')});
  console.log(JSON.stringify({event:'previews.requested',sources:selected.map(s=>({id:s.id,width:s.contentWidth,height:s.contentHeight}))}));
}
async function adoptHeadset() {
  const ids = await until(async () => {
    const text = await fs.readFile(path.join(home,'logs/mac-companion/current.jsonl'),'utf8');
    const ids = [...new Set(text.trim().split('\n').flatMap(line => {
      try { const e=JSON.parse(line); return e.source==='vision-client' && e.fields?.clientId && e.fields.clientId!==operatorClientID ? [e.fields.clientId] : []; } catch { return []; }
    }))];
    return ids.length ? ids : undefined;
  }, 45000);
  if(ids.length!==1 || !/^[a-f0-9-]{36}$/i.test(ids[0])) throw new Error('Expected one persisted headset client ID');
  if(clientID!==operatorClientID && clientID!==ids[0]) throw new Error('Headset client ID changed across restart');
  clientID=ids[0];
  await layoutAdd(sessionIDs.map(id=>({id,kind:'terminal',targetID:id})));
  const setup=JSON.parse(await fs.readFile(path.join(run,'setup.private.json'),'utf8'));
  await fs.writeFile(path.join(run,'setup.private.json'),JSON.stringify({...setup,clientID}),{mode:0o600});
  await journal('headset.client.adopted',{clientID});
  console.log(JSON.stringify({event:'headset.client.adopted',clientID}));
}
async function restartHelper() {
  const events=(await fs.readFile(path.join(home,'logs/mac-companion/current.jsonl'),'utf8')).trim().split('\n').map(line=>JSON.parse(line));
  const pid=events.findLast(e=>e.event==='helper.ready')?.fields?.pid;
  const desktop=await readPrivateStatus();
  const ppid=pid && Number(execFileSync('/bin/ps',['-o','ppid=','-p',String(pid)],{encoding:'utf8'}).trim());
  const httpParent=Number(execFileSync('/bin/ps',['-o','ppid=','-p',String(desktop.pid)],{encoding:'utf8'}).trim());
  if (!Number.isInteger(pid) || ppid!==desktop.pid || (!smoke && httpParent!==child.pid)) throw new Error('Helper is not a verified child of this isolated app');
  await journal('helper.interruption.before',{pid,companionPid:desktop.pid});
  process.kill(pid,'SIGTERM');
  console.log(JSON.stringify({event:'helper.interrupted',pid}));
}
async function stop() {
  if (stopped) return; stopped=true;
  if (mcpClient) { await mcpClient.close(); mcpClient=undefined; }
  await writeFixture({covered:false,closed:true});
  try {
    const desktop=await readPrivateStatus();
    const homeKey=createHash('sha256').update(await fs.realpath(home)).digest('hex').slice(0,24);
    const expected=`/tmp/slz-sessions-${process.getuid()}-${homeKey}/service.sock`;
    if (desktop.sessionSocketPath!==expected) throw new Error('Session service socket does not match owned test home');
    await new Promise((resolve,reject)=>{const req=http.request({socketPath:expected,path:'/stop',method:'POST'},res=>{res.resume();res.on('end',resolve);});req.setTimeout(5000,()=>req.destroy(new Error('Service stop timeout')));req.on('error',reject);req.end();});
  } catch(error) { await journal('cleanup.service',{error:error.message}); }
  if (child && child.exitCode===null && child.signalCode===null) { child.kill('SIGTERM'); await until(()=>child.exitCode!==null || child.signalCode!==null,15000); }
  if (fixture && fixture.exitCode===null && fixture.signalCode===null) fixture.kill('SIGTERM');
  if (!smoke) { try {execFileSync('xcrun',['simctl','shutdown',simulator],{stdio:'pipe',timeout:20000});}catch{} }
  await journal('stopped'); console.log(JSON.stringify({event:'stopped',run}));
}
try {
  const log=await fs.open(path.join(run,'operator-child.private.log'),'a',0o600);
  child=spawn(smoke ? path.join(resources,'runtime/node') : path.join(mac,'Contents/MacOS/SlopZooka'),smoke ? ['--require',path.join(resources,'session-runtime/bootstrap.cjs'),path.join(resources,'host/src/server.mjs')] : [],{cwd:run,env,stdio:['pipe',log.fd,log.fd]});
  await log.close(); child.on('error',error=>console.error(JSON.stringify({event:'child.error',error:error.message})));
  await until(async()=>{try{return (await api('/health')).sessionServiceAvailable;}catch{return false;}});
  const desktop=await until(async()=>{try{return await readPrivateStatus();}catch{return false;}});
  const pair=await api('/api/pair','POST',{code:desktop.code}); token=pair.token; hostID=pair.hostId;
  if (!token || !hostID) throw new Error('Operator pairing failed');
  for (const id of sessionIDs) {
    await api('/api/workspaces/preview-test/sessions','POST',{profile:'codex',sessionId:id});
    await api(`/api/sessions/${id}`,'PATCH',{name:id==='preview-a'?'Preview Test A':'Preview Test B'});
  }
  await layoutAdd(sessionIDs.map(id=>({id,kind:'terminal',targetID:id})));
  await fs.writeFile(path.join(run,'setup.private.json'),JSON.stringify({run,home,base,address:`${address}:${port}`,clientID,hostID,token,device,vpBundle,simulator},null,2),{mode:0o600});
  await fs.writeFile(path.join(baseDir,smoke?'smoke-current.json':'current.json'),JSON.stringify({run}),{mode:0o600});
  await status();
  if (smoke) {
    await pulse();
    const require=createRequire(path.join(root,'apps/mac-companion/package.json'));
    const {WebSocket}=require('ws');
    for(const id of sessionIDs) {
      const ws=new WebSocket(base.replace('http:','ws:')+'/ws',{headers:{Authorization:`Bearer ${token}`}});
      await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>{ws.terminate();reject(new Error('Terminal replay timeout'));},8000);
        ws.on('error',reject);
        ws.on('message',bytes=>{const msg=JSON.parse(String(bytes));if(msg.type==='hello')ws.send(JSON.stringify({type:'attach',sessionId:id}));
          if(msg.type==='attached' && msg.snapshot?.includes(`ACK ${id}-${fixtureState.nonce}`)){clearTimeout(timer);ws.close();resolve();}});
      });
    }
    console.log(JSON.stringify({event:'smoke.passed',checks:['packaged-health','private-status','normal-pairing','two-real-PTYs','layout-CAS','fresh-input-ACKs','two-WebSocket-replays']}));
    if (mcpMode) {
      const client=await connectMCP();
      const tools=(await client.listTools()).tools.map(t=>t.name).sort();
      if(JSON.stringify(tools)!==JSON.stringify(['preview_close','preview_list','preview_open','preview_rename']))throw new Error('Unexpected packaged MCP tools');
      const listed=await callMCP('preview_list');
      if(listed.isError)throw new Error('Packaged MCP catalog failed');
      const unavailable=await callMCP('preview_open',{source_id:'window:smoke-unavailable'});
      if(!unavailable.isError)throw new Error('Disabled capture accepted open');
      await journal('mcp.smoke.passed',{tools:tools.join(',')});
    }
    await journal('smoke.passed');
  } else {
    // Only --live, after the user gives the slot, creates visible fixture windows.
    execFileSync('xcrun',['simctl','boot',simulator],{stdio:'pipe',timeout:15000});
    execFileSync('xcrun',['simctl','bootstatus',simulator,'-b'],{stdio:'pipe',timeout:120000});
    execFileSync('xcrun',['simctl','install',simulator,path.join(baseDir,'fixtures/IOSFixture.app')],{stdio:'pipe',timeout:30000});
    const iosContainer=execFileSync('xcrun',['simctl','get_app_container',simulator,iosBundle,'data'],{encoding:'utf8',timeout:10000}).trim();
    iosStateFile=path.join(iosContainer,'Documents/preview-state.json');
    await fs.mkdir(path.dirname(iosStateFile),{recursive:true});
    await fs.writeFile(iosStateFile,JSON.stringify({nonce:fixtureState.nonce}));
    execFileSync('xcrun',['simctl','launch',simulator,iosBundle],{stdio:'pipe',timeout:15000});
    execFileSync('/usr/bin/open',['-a','Simulator','--args','-CurrentDeviceUDID',simulator],{stdio:'pipe',timeout:10000});
    fixture=spawn(path.join(baseDir,'fixtures/NativeFixture.app/Contents/MacOS/NativeFixture'),[stateFile],{stdio:'ignore'});
    await journal('live.ready',{pid:child.pid,fixturePID:fixture.pid});
    console.log(JSON.stringify({event:'ready',run,commands:['status','code','permission','settings','sources','open','launch','adopt','mcp <tool> <JSON>','restart-viewer','pulse','portrait','landscape','cover','uncover','close-source','restart-helper','stop']}));
    for await(const line of createInterface({input:process.stdin})) {
      try {
        const command=line.trim();
        if(command==='stop')break;
        if(command==='status')await status();
        else if(command==='code'){const s=await readPrivateStatus();if(Date.now()-s.at>10000)throw new Error('Private status stale');console.log(JSON.stringify({pairingCode:s.code,address:`${address}:${port}`}));}
        else if(command==='permission'||command==='settings')await api('/api/window-previews/permission','POST',{settings:command==='settings'});
        else if(command==='sources')console.log(JSON.stringify((await sources()).map(s=>({id:s.id,width:s.contentWidth,height:s.contentHeight}))));
        else if(command==='open'){if(mcpMode)throw new Error('Use mcp preview_open in MCP validation mode');await openPreviews();}
        else if(command==='adopt'){await adoptHeadset();if(mcpClient){await mcpClient.close();mcpClient=undefined;}if(!mcpMode)await openPreviews();}
        else if(command.startsWith('mcp ')){
          const match=command.match(/^mcp (preview_(?:list|open|rename|close))(?: (.*))?$/);
          if(!match)throw new Error('Expected mcp preview_<tool> followed by optional JSON arguments');
          await callMCP(match[1],match[2]?JSON.parse(match[2]):{});
        }
        else if(command==='restart-viewer'){
          if(clientID===operatorClientID)throw new Error('Adopt the real headset client before restart');
          execFileSync('xcrun',['devicectl','device','process','launch','--device',device,'--terminate-existing','--',vpBundle],{stdio:'pipe',timeout:60000});
          await journal('headset.restarted.withoutOverrides');
        }
        else if(command==='launch'){
          execFileSync('xcrun',['devicectl','device','install','app','--device',device,vpApp],{stdio:'pipe',timeout:120000});
          execFileSync('xcrun',['devicectl','device','process','launch','--device',device,'--terminate-existing','--',vpBundle,'-companionHost',`${address}:${port}`,'-companionHostID',hostID],{stdio:'pipe',timeout:60000});
          await journal('headset.launched');console.log(JSON.stringify({event:'headset.launched'}));
        }else if(command==='pulse')await pulse();
        else if(command==='portrait'||command==='landscape')await writeFixture({portrait:command==='portrait'});
        else if(command==='cover'||command==='uncover')await writeFixture({covered:command==='cover'});
        else if(command==='close-source')await writeFixture({closed:true});
        else if(command==='restart-helper')await restartHelper();
        else if(command.startsWith('note '))await journal('operator.note',{note:command.slice(5)});
        else throw new Error('Unknown command');
        await journal('command.done',{command:command.split(' ')[0]});
      }catch(error){console.log(JSON.stringify({event:'command.failed',error:error.message}));await journal('command.failed',{error:error.message});}
    }
  }
}finally{await stop();process.stdin.destroy();}
