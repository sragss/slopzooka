import json
import sys
import base64
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time

manifest = Path.home() / '.codex/plugins/cache/openai-bundled/unified-computer-use/26.1023.51421/.mcp.json'
server = json.loads(manifest.read_text())['mcpServers']['cua_repl']
env = {k: os.environ[k] for k in ['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'USER', 'LOGNAME'] if k in os.environ}
env.update(server.get('env', {}))
env['CUA_REPL_ENABLED_SURFACES'] = 'computer'
print(json.dumps({'stage':'runtime-environment','inheritedTaskVariables':[k for k in ['CODEX_SESSION_ID','CODEX_THREAD_ID','CODEX_TOOL_CALL_ID','NODE_REPL_HOST_SERVICES_PIPE_PATH'] if k in env],'turnMetadataSent':False}),flush=True)
process = subprocess.Popen([server['command'], *server['args']], env=env, cwd='/tmp', stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
buffers = {'stdout': b'', 'stderr': b''}
events = []

def send(value):
    process.stdin.write((json.dumps(value) + '\n').encode())
    process.stdin.flush()

def receive(request_id, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'Own MCP process exited: {process.returncode}')
        for key, _ in selector.select(min(0.25, max(0, deadline-time.monotonic()))):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            source = key.data
            buffers[source] += chunk
            while b'\n' in buffers[source]:
                raw, buffers[source] = buffers[source].split(b'\n', 1)
                if source == 'stderr':
                    events.append({'stderr': raw.decode(errors='replace')[:900]})
                    continue
                try:
                    row = json.loads(raw)
                except Exception:
                    events.append({'nonJSONStdoutBytes': len(raw)})
                    continue
                if row.get('id') == request_id and ('result' in row or 'error' in row):
                    return row
                if 'method' in row and 'id' in row:
                    events.append({'serverRequest': row['method']})
                    if row['method'] == 'elicitation/create':
                        params = row.get('params', {})
                        metadata = params.get('_meta', params.get('meta', {}))
                        target = metadata.get('tool_params', {}).get('app')
                        # This task authorizes only our disposable fixture for this probe.
                        approved = '--fixture' in sys.argv and metadata.get('connector_id') == 'computer-use' and target == 'dev.slopzooka.codex-runtime-fixture'
                        print(json.dumps({'stage':'elicitation','target':target,'decision':'accept' if approved else 'cancel','scope':'owned disposable fixture only'}),flush=True)
                        send({'jsonrpc':'2.0','id':row['id'],'result':{'action':'accept' if approved else 'cancel'}})
                    else:
                        send({'jsonrpc':'2.0','id':row['id'],'error':{'code':-32601,'message':'Probe client does not implement this host capability'}})
                elif row.get('method'):
                    events.append({'notification': row['method']})
    raise TimeoutError(f'No response to request {request_id} within {seconds}s')

try:
    send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{'elicitation':{}},'clientInfo':{'name':'slz-runtime-probe','version':'0.1'}}})
    initialized = receive(1)
    info = initialized.get('result', {})
    print(json.dumps({'stage':'initialize','serverInfo':info.get('serverInfo'),'protocolVersion':info.get('protocolVersion'),'error':initialized.get('error')}),flush=True)
    send({'jsonrpc':'2.0','method':'notifications/initialized'})
    send({'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}})
    catalog = receive(2)
    print(json.dumps({'stage':'tools/list','tools':[x['name'] for x in catalog.get('result',{}).get('tools',[])],'error':catalog.get('error')}),flush=True)
    send({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'js','arguments':{'code':'await cua.getState();','timeout_ms':5000,'title':'Read-only standalone CUA runtime probe'}}})
    response = receive(3, 25)
    result = response.get('result', {})
    text_blocks = [x.get('text','') for x in result.get('content',[]) if x.get('type') == 'text']
    # Successful inventory text is private and intentionally omitted.
    errors = [x[:2000] for x in text_blocks if any(word in x.lower() for word in ['error:', 'exception', 'requires the trusted', 'unavailable', 'not authenticated', 'no active session', 'failed to'])]
    print(json.dumps({'stage':'getState','isError':result.get('isError',False),'contentTypes':[x.get('type') for x in result.get('content',[])],'textBytes':sum(map(len,text_blocks)),'errorExcerpts':[x for x in errors if not x.startswith('## Computer Use')],'textSummaries':[{'bytes':len(x),'preview':'[inventory omitted]' if x.startswith('{"apps"') else ('[bootstrap API documentation]' if x.startswith('## Computer Use') else x[:600])} for x in text_blocks],'rpcError':response.get('error')}),flush=True)
    if '--fixture' in sys.argv:
        print(json.dumps({'stage':'ready','instructions':'Supply one JSON object with code per line; {exit:true} ends the owned runtime.'}),flush=True)
        request_id = 10
        for line in sys.stdin:
            command = json.loads(line)
            if command.get('exit'):
                break
            send({'jsonrpc':'2.0','id':request_id,'method':'tools/call','params':{'name':'js','arguments':{'code':command['code'],'timeout_ms':10000,'title':'Disposable fixture runtime probe'}}})
            response = receive(request_id, 30)
            result = response.get('result', {})
            parts = []
            for index, content in enumerate(result.get('content', [])):
                if content.get('type') == 'image':
                    image_path = Path('/tmp/slz-codex-runtime-fixture') / f'observation-{request_id}-{index}.png'
                    image_path.write_bytes(base64.b64decode(content['data']))
                    parts.append({'imagePath':str(image_path),'mimeType':content.get('mimeType')})
                elif content.get('type') == 'text':
                    value = content.get('text','')
                    parts.append({'text':value[:9000] if not value.startswith('## Computer Use') else '[bootstrap API documentation]'})
            print(json.dumps({'stage':'fixture-call','id':request_id,'isError':result.get('isError',False),'content':parts,'error':response.get('error')}),flush=True)
            request_id += 1
except Exception as error:
    print(json.dumps({'stage':'probe','errorName':type(error).__name__,'message':str(error)}),flush=True)
finally:
    try:
        process.stdin.close()
        process.wait(timeout=3)
    except (subprocess.TimeoutExpired, BrokenPipeError):
        pass
    # Only the process group created by this probe is eligible for cleanup.
    try: os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError: pass
    try: process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
    selector.close()
    print(json.dumps({'stage':'cleanup','returnCode':process.returncode,'diagnostics':events[-8:]}),flush=True)
