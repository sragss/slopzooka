#!/usr/bin/env node
// Disposable native-provider stand-in; never captures a screen or asks permission.
import net from 'node:net';
import fs from 'node:fs';
import readline from 'node:readline';
import { randomUUID } from 'node:crypto';
const stateFile = '__STATE_FILE__';
const sourceID = `window:${randomUUID()}:42:99`;
const tickets = new Set();
const sockets = new Set();
const emit = (value) => process.stdout.write(JSON.stringify({ version: 1, ...value }) + '\n');
const server = net.createServer((socket) => {
  sockets.add(socket); socket.once('close', () => sockets.delete(socket));
  socket.on('error', () => {});
  let admitted = false;
  let header = '';
  socket.on('data', (data) => {
    if (!admitted) {
      header += data.toString();
      if (!header.endsWith('\n')) return;
      if (!tickets.delete(header.trim())) { socket.destroy(); return; }
      admitted = true;
      socket.write(Buffer.from([0, 255, 1, 254]));
    } else socket.write(data); // Binary echo proves the bridge never interprets media.
  });
});
server.listen(0, '127.0.0.1', () => emit({ type: 'ready', port: server.address().port }));
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const command = JSON.parse(line);
  const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  if (state.crash) process.exit(3);
  if (state.malformed) { process.stdout.write('{"version":99}\n'); return; }
  let value;
  if (command.method === 'catalog') value = { state: state.state ?? 'ready', sources: state.gone ? [] : [{ id: sourceID, title: 'Fixture', application: 'Native fixture', contentWidth: 390, contentHeight: 844 }] };
  else if (command.method === 'open') {
    const ticket = randomUUID(); tickets.add(ticket); value = { ticket };
  } else value = { ok: true };
  // Exercise control-line fragmentation and uppercase UUIDs used by Swift.
  const reply = JSON.stringify({ version: 1, type: 'reply', id: command.id.toUpperCase(), value }) + '\n';
  process.stdout.write(reply.slice(0, 14)); setImmediate(() => process.stdout.write(reply.slice(14)));
}).on('close', () => process.exit(0));
