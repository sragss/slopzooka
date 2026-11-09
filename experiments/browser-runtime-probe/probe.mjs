// Disposable, model-free comparison. Vendor packages and output stay in ignored build/.
import { createServer } from 'node:http';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, mkdtemp, readFile, writeFile, appendFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { chromium } from './build/runtime/node_modules/playwright-core/index.mjs';
import { createConnection } from './build/runtime/node_modules/@playwright/mcp/index.js';
import { Client } from './build/runtime/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StdioClientTransport } from './build/runtime/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';
import { InMemoryTransport } from './build/runtime/node_modules/@modelcontextprotocol/sdk/dist/esm/inMemory.js';

const base = dirname(fileURLToPath(import.meta.url));
const build = join(base, 'build');
await mkdir(build, { recursive: true });
const run = await mkdtemp(join(build, 'run-'));
const profile = join(run, 'chrome-profile');
await mkdir(profile);
await writeFile(join(run, 'agent-config.json'), '{}\n');
const fixture = await readFile(join(base, 'fixture.html'));
const events = [];
const records = [];
const clients = new Map();
const servers = [];
const contexts = [];
const execFileAsync = promisify(execFile);
const agentBinary = join(base, 'build/runtime/node_modules/agent-browser/bin/agent-browser-darwin-arm64');
const sessions = Object.fromEntries(['agent-a', 'agent-b'].map(actor => [actor, `slz-${run.split('/').at(-1)}-${actor}`]));
const usedSessions = new Set();
const ordinaryEnv = Object.fromEntries(['PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'USER', 'LOGNAME'].filter(k => process.env[k]).map(k => [k, process.env[k]]));
const server = createServer(async (req, res) => {
  if (req.url === '/event' && req.method === 'POST') {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    events.push({ ...JSON.parse(Buffer.concat(chunks)), receivedAt: new Date().toISOString() });
    res.writeHead(200).end('ok');
  } else if (req.url === '/frame') {
    res.setHeader('Content-Type', 'text/html');
    res.end('<button onclick="this.textContent=\'Frame clicked\'">Frame action</button>');
  } else {
    res.setHeader('Content-Type', 'text/html');
    res.end(fixture);
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let chrome, chromeExited, browser;
async function record(row) {
  records.push(row);
  await appendFile(join(run, 'trace.jsonl'), JSON.stringify(row) + '\n');
  console.log(JSON.stringify(row));
}
function compact(result) {
  return { ...result, content: result.content?.map(c => c.type === 'image' ? { type: c.type, mimeType: c.mimeType, base64Bytes: c.data.length } : c) };
}
async function callAgent(actor, args) {
  usedSessions.add(actor);
  const command = ['--config', join(run, 'agent-config.json'), '--session', sessions[actor], '--json', ...args];
  try {
    const result = await execFileAsync(agentBinary, command, { env: ordinaryEnv, cwd: run, timeout: 20000, maxBuffer: 1024 * 1024 });
    return { exitCode: 0, ...result };
  } catch (error) {
    return { exitCode: error.code, stdout: error.stdout, stderr: error.stderr, message: error.message };
  }
}
try {
  chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
    `--user-data-dir=${profile}`, '--headless=new', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0', 'about:blank'
  ], { env: ordinaryEnv, stdio: ['ignore', 'ignore', 'pipe'] });
  chromeExited = new Promise(resolve => chrome.once('exit', resolve));
  let chromeDiagnostics = '';
  chrome.stderr.on('data', data => { chromeDiagnostics = (chromeDiagnostics + data).slice(-8000); });
  let port;
  for (let i = 0; i < 80; i++) {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; break; }
    catch { await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  if (!port) throw new Error(`Owned Chrome did not start: ${chromeDiagnostics}`);
  const endpoint = `http://127.0.0.1:${port}`;
  const info = await (await fetch(`${endpoint}/json/version`)).json();
  browser = await chromium.connectOverCDP(endpoint);
  for (const actor of ['playwright-a', 'playwright-b']) {
    const context = await browser.newContext();
    contexts.push(context);
    const mcpServer = await createConnection({ outputDir: run }, async () => context);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await mcpServer.connect(serverTransport);
    const client = new Client({ name: actor, version: '0.1' });
    await client.connect(clientTransport);
    clients.set(actor, client);
    servers.push(mcpServer);
  }
  const playwriter = new Client({ name: 'slz-playwriter-probe', version: '0.1' });
  const transport = new StdioClientTransport({
    command: '/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node',
    args: [join(base, 'build/runtime/node_modules/playwriter/bin.js')],
    env: { ...ordinaryEnv, PLAYWRITER_DIRECT: info.webSocketDebuggerUrl, PLAYWRITER_TELEMETRY: '0', DO_NOT_TRACK: '1' },
    cwd: run, stderr: 'pipe'
  });
  transport.stderr?.on('data', data => appendFile(join(run, 'playwriter-stderr.txt'), data).catch(() => {}));
  await playwriter.connect(transport);
  clients.set('playwriter', playwriter);
  for (const [actor, client] of clients) {
    const catalog = await client.listTools();
    await writeFile(join(run, `${actor}-catalog.json`), JSON.stringify(catalog, null, 2));
  }
  await record({ stage: 'ready', run, origin, endpoint, chromePid: chrome.pid, browser: info.Browser, actors: [...clients.keys(), ...Object.keys(sessions)] });
  for await (const line of createInterface({ input: process.stdin })) {
    if (!line.trim()) continue;
    const request = JSON.parse(line);
    if (request.exit) break;
    const started = performance.now();
    try {
      let result;
      if (request.observe) {
        result = { events, pages: await Promise.all(browser.contexts().flatMap(c => c.pages()).map(async p => ({ url: p.url(), title: await p.title() }))) };
      } else if (request.closeUrl) {
        const pages = browser.contexts().flatMap(c => c.pages()).filter(p => p.url() === request.closeUrl);
        if (pages.length !== 1) throw new Error('Close requires one exact owned fixture page');
        await pages[0].close(); result = { closed: request.closeUrl };
      } else if (request.disconnect) {
        await clients.get(request.disconnect).close();
        clients.delete(request.disconnect);
        result = { disconnected: request.disconnect };
      } else if (request.actor.startsWith('agent-')) {
        result = await callAgent(request.actor, request.args);
      } else {
        const response = await clients.get(request.actor).callTool({ name: request.tool, arguments: request.arguments ?? {} });
        for (const [index, block] of (response.content ?? []).entries()) {
          if (block.type === 'image') await writeFile(join(run, `image-${records.length}-${index}.${block.mimeType === 'image/png' ? 'png' : 'jpg'}`), Buffer.from(block.data, 'base64'));
        }
        result = compact(response);
      }
      await record({ request, elapsedMs: Math.round(performance.now() - started), result });
    } catch (error) {
      await record({ request, elapsedMs: Math.round(performance.now() - started), error: String(error) });
    }
  }
} catch (error) {
  await record({ stage: 'fatal', error: String(error) });
  process.exitCode = 1;
} finally {
  for (const actor of usedSessions) await record({ stage: 'agent-cleanup', actor, result: await callAgent(actor, ['close']) });
  for (const [actor, client] of clients) {
    try { await client.close(); } catch (error) { await record({ stage: 'client-cleanup-error', actor, error: String(error) }); }
  }
  for (const mcpServer of servers) await mcpServer.close().catch(() => {});
  for (const context of contexts) await context.close().catch(() => {});
  if (browser) await browser.close().catch(() => {});
  if (chrome && chrome.exitCode === null) chrome.kill('SIGTERM');
  if (chromeExited) await Promise.race([chromeExited, new Promise(resolve => setTimeout(resolve, 3000))]);
  await new Promise(resolve => server.close(resolve));
  await writeFile(join(run, 'events.json'), JSON.stringify(events, null, 2));
  await record({ stage: 'cleanup', fixtureEvents: events.length, ownedChromeExitCode: chrome?.exitCode, ownedChromeSignal: chrome?.signalCode });
  process.stdin.pause();
  process.stdin.unref?.();
}
