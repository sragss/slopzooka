// Dependency-free fixture for the installed Codex browser runtime.
// This serves test content only; it does not launch Chrome or provision access.
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, appendFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const base = dirname(fileURLToPath(import.meta.url));
const build = join(base, 'build');
await mkdir(build, { recursive: true });
const run = await mkdtemp(join(build, 'codex-baseline-'));
const fixture = await readFile(join(base, 'fixture.html'));
const events = [];
let pendingWrites = Promise.resolve();
let origin;
const server = createServer((req, res) => {
  handle(req, res).catch(error => {
    console.error(JSON.stringify({ stage: 'request-error', message: error.message }));
    if (!res.headersSent) res.writeHead(500);
    res.end('Fixture request failed');
  });
});

async function handle(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.headers.host !== new URL(origin).host) {
    res.writeHead(403).end('Unexpected host');
    return;
  }
  if (req.method === 'GET' && ['/a', '/b'].includes(req.url)) {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end(fixture);
  } else if (req.method === 'GET' && req.url === '/frame') {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end('<button onclick="this.textContent=\'Frame clicked\'">Frame action</button>');
  } else if (req.method === 'GET' && req.url === '/events') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(events));
  } else if (req.method === 'POST' && req.url === '/event') {
    if (req.headers.origin !== origin) {
      res.writeHead(403).end('Unexpected origin');
      return;
    }
    let body = '';
    for await (const chunk of req) {
      body += chunk;
      if (Buffer.byteLength(body) > 4096) {
        res.writeHead(413).end('Fixture event too large');
        return;
      }
    }
    let event;
    try { event = JSON.parse(body); } catch {
      res.writeHead(400).end('Invalid JSON');
      return;
    }
    if (!['/a', '/b'].includes(event?.fixture)
        || !['save', 'increment', 'settings'].includes(event?.action)
        || !Number.isSafeInteger(event?.count) || event.count < 0
        || typeof event?.label !== 'string' || event.label.length > 128) {
      res.writeHead(400).end('Invalid fixture event');
      return;
    }
    if (events.length >= 1000) {
      res.writeHead(429).end('Start a fresh fixture run');
      return;
    }
    const row = {
      sequence: events.length + 1,
      fixture: event.fixture, action: event.action, count: event.count,
      label: event.label, receivedAt: new Date().toISOString(),
    };
    events.push(row);
    pendingWrites = pendingWrites.then(() => appendFile(join(run, 'events.jsonl'), JSON.stringify(row) + '\n'));
    await pendingWrites;
    res.writeHead(200).end('ok');
    console.log(JSON.stringify({ stage: 'fixture-event', ...row }));
  } else {
    res.writeHead(404).end('Use the exact /a or /b fixture URL');
  }
}

await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
console.log(JSON.stringify({ stage: 'ready', pid: process.pid, run, urls: [`${origin}/a`, `${origin}/b`], events: `${origin}/events` }));
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  server.closeIdleConnections();
  await new Promise(resolve => server.close(resolve));
  await pendingWrites;
  console.log(JSON.stringify({ stage: 'stopped', eventCount: events.length }));
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
