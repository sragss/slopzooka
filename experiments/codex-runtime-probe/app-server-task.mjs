// One explicitly authorized browser-fixture task on an already-running App Server.
// Does not provision desktop authority, copy another task's identity, or edit config.
import WebSocket from '../browser-runtime-probe/build/runtime/node_modules/ws/wrapper.mjs';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, mkdtemp, readFile, writeFile, appendFile, rmdir } from 'node:fs/promises';

const version = '26.1103.60933';
const actualVersion = execFileSync('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', '/Applications/ChatGPT.app/Contents/Info.plist'], { encoding: 'utf8' }).trim();
if (actualVersion !== version) throw new Error(`Reinspect desktop version ${actualVersion} before running this pinned probe`);
const target = new URL(process.argv[2] ?? 'http://127.0.0.1:62221/b');
if (target.protocol !== 'http:' || target.hostname !== '127.0.0.1' || target.pathname !== '/b' || target.search || target.hash || target.username || target.password) {
  throw new Error('Only the owned loopback /b fixture is accepted');
}
const before = await (await fetch(`${target.origin}/events`)).json();
const daemon = JSON.parse(execFileSync('codex', ['app-server', 'daemon', 'version'], { encoding: 'utf8' }));
if (daemon.status !== 'running' || daemon.appServerVersion !== '0.167.0') throw new Error('Expected the already-running, inspected App Server 0.167.0');
const manifestPath = join(homedir(), `.codex/plugins/cache/openai-bundled/unified-computer-use/${version}/.mcp.json`);
const manifest = JSON.parse(await readFile(manifestPath, 'utf8')).mcpServers.cua_repl;
const env = { ...manifest.env, CUA_REPL_ENABLED_SURFACES: 'browser' };
const base = dirname(fileURLToPath(import.meta.url));
await mkdir(join(base, 'build'), { recursive: true });
const run = await mkdtemp(join(base, 'build/app-server-task-'));
const cwd = await mkdtemp(join(tmpdir(), 'slz-browser-task-'));
const serverName = 'slz_browser_probe';
const pending = new Map();
let nextId = 1;
let threadId;
let turnId;
let turnComplete = false;
let resolveCompletion;
const completion = new Promise(resolve => { resolveCompletion = resolve; });
let writes = Promise.resolve();

function compact(value) {
  if (Array.isArray(value)) return value.map(compact);
  if (!value || typeof value !== 'object') return value;
  if (value.type === 'image') return { type: value.type, mimeType: value.mimeType, imageBytesOmitted: true };
  return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, k === '_meta' || k === 'env' ? '[omitted]' : compact(v)]));
}
function record(row) {
  const safe = compact({ at: new Date().toISOString(), ...row });
  writes = writes.then(() => appendFile(join(run, 'trace.jsonl'), JSON.stringify(safe) + '\n'));
  console.log(JSON.stringify(safe));
}
const ws = new WebSocket(`ws+unix://${daemon.socketPath}:/`, { handshakeTimeout: 8000 });
ws.on('error', error => record({ stage: 'socket-error', message: error.message }));
ws.on('close', () => {
  for (const { reject } of pending.values()) reject(new Error('App Server connection closed'));
  pending.clear();
  if (turnId && !turnComplete) resolveCompletion({ status: 'connection-lost' });
});
function send(value) { ws.send(JSON.stringify(value)); }
async function request(method, params, timeoutMs = 30000) {
  const id = nextId++;
  let timeout;
  try {
    return await Promise.race([
      new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); send({ id, method, params }); }),
      new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error(`${method} reply timeout; do not blindly retry mutations`)), timeoutMs); }),
    ]);
  } finally { clearTimeout(timeout); pending.delete(id); }
}
ws.on('message', data => {
  const row = JSON.parse(data.toString());
  if (!row.method && pending.has(row.id)) {
    const waiter = pending.get(row.id);
    if (row.error) waiter.reject(new Error(JSON.stringify(row.error)));
    else waiter.resolve(row.result);
    return;
  }
  if (row.method && row.id !== undefined) {
    // Site approval cannot be inferred from an arbitrary host request. Stop and
    // record a new elicitation rather than granting access outside the fixture.
    record({ stage: 'server-request', method: row.method, params: row.params, disposition: 'cancel' });
    if (row.method === 'mcpServer/elicitation/request') send({ id: row.id, result: { action: 'cancel' } });
    else send({ id: row.id, error: { code: -32601, message: 'Fixture client does not authorize this host capability' } });
    return;
  }
  if (row.params?.threadId !== threadId || !threadId) return;
  if (row.method === 'turn/started') {
    turnId = row.params.turn.id;
    record({ stage: 'turn-started', turnId });
  } else if (row.method === 'turn/completed') {
    turnComplete = true;
    record({ stage: 'turn-completed', turn: row.params.turn });
    resolveCompletion(row.params.turn);
  } else if (row.method === 'item/completed' && ['mcpToolCall', 'agentMessage'].includes(row.params.item?.type)) {
    record({ stage: 'item-completed', item: row.params.item });
  } else if (row.method === 'error' || row.method === 'mcpServer/startupStatus/updated') {
    record({ stage: row.method, params: row.params });
  }
});

const instructions = `You are the test subject in a user-authorized browser-runtime qualification. Use only the ${serverName} MCP server. Do not use shell commands, other servers, native Mac app control, the built-in browser, web search, file access or other agents. Your first computer-use call must be await cua.getBrowser({ id: "chrome" });. Follow its returned API guidance if it succeeds. If the browser service reports an authorization, host, current-turn, or unavailable-runtime error, report the exact error and stop; do not alter configuration, synthesize identity, or switch providers. If it succeeds, open only ${target.href} in Google Chrome with sessionName "SlopZooka external task", save codex-b as Workspace label, click Increment twice, open Settings, verify the rendered state and obtain a screenshot through the tool. Mark only this fixture tab as a deliverable if that API is available. Do not read or change other tabs. Browser site approval, if required, must be limited to this loopback fixture. Return a short verdict distinguishing tool initialization from actual page effects.`;

try {
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  const initialized = await request('initialize', {
    clientInfo: { name: 'slz_browser_qualification', title: 'SlopZooka browser qualification', version: '0.2.0' },
    capabilities: { experimentalApi: true, mcpServerOpenaiFormElicitation: true },
  });
  send({ method: 'initialized', params: {} });
  record({ stage: 'ready', run, cwd, target: target.href, appServerVersion: daemon.appServerVersion, platform: initialized.platformOs, beforeEventCount: before.length });
  const started = await request('thread/start', {
    cwd, ephemeral: true, sandbox: 'read-only', developerInstructions: instructions,
    config: {
      'features.apps': false,
      'features.plugins': false,
      'features.shell_tool': false,
      web_search: 'disabled',
      mcp_servers: {
        [serverName]: { command: manifest.command, args: manifest.args, env, enabled: true, required: true, startup_timeout_sec: 30, tool_timeout_sec: 30 },
      },
    },
  }, 45000);
  threadId = started.thread.id;
  record({ stage: 'thread-created', threadId, sessionId: started.thread.sessionId, model: started.model, sandbox: started.sandbox, ephemeral: true });
  const status = await request('mcpServerStatus/list', { threadId, serverName, limit: 10 }, 45000);
  await writeFile(join(run, 'mcp-catalog.json'), JSON.stringify(compact(status), null, 2) + '\n');
  record({ stage: 'mcp-status', data: status.data?.map(s => ({ name: s.name, toolNames: Object.keys(s.tools ?? {}), authStatus: s.authStatus })) });
  const turn = await request('turn/start', {
    threadId,
    input: [{ type: 'text', text: `Run the authorized qualification using ${serverName}: try Google Chrome through the installed runtime, and operate only ${target.href} as instructed. Stop at an authorization or provisioning error and report it exactly.`, text_elements: [] }],
  });
  turnId = turn.turn.id;
  record({ stage: 'turn-accepted', turnId });
  const outcome = await completion;
  const after = await (await fetch(`${target.origin}/events`)).json();
  await writeFile(join(run, 'result.json'), JSON.stringify({ threadId, turnId, status: outcome.status, error: outcome.error, newFixtureEvents: after.slice(before.length) }, null, 2) + '\n');
  record({ stage: 'fixture-result', newEvents: after.slice(before.length) });
} catch (error) {
  record({ stage: 'probe-error', message: error.message });
} finally {
  if (ws.readyState === WebSocket.OPEN && threadId) {
    if (turnId && !turnComplete) {
      try { await request('turn/interrupt', { threadId, turnId }); } catch (error) { record({ stage: 'interrupt-error', message: error.message }); }
    }
    try { await request('thread/unsubscribe', { threadId }); } catch (error) { record({ stage: 'unsubscribe-error', message: error.message }); }
  }
  ws.terminate();
  await rmdir(cwd).catch(() => {}); // Remove only the empty directory we made.
  record({ stage: 'cleanup', existingServerStopped: false, threadId, turnId });
  await writes;
}
