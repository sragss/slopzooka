import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { connect } from "node:net";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
execFileSync(process.execPath, ["apps/mac-companion/scripts/build-windows.mjs"], {
  cwd: root, stdio: "inherit", timeout: 60000,
});
const child = spawn("apps/mac-companion/native/window-host", [], {
  cwd: root, stdio: ["pipe", "pipe", "inherit"],
});
const exited = once(child, "exit");
const lines = createInterface({ input: child.stdout });
const received = [];
const pending = [];
let summaries = 0;
lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "observation") { summaries += 1; return; }
  const waiter = pending.shift();
  if (waiter) waiter(message);
  else received.push(message);
});
async function next() {
  if (received.length) return received.shift();
  let timer;
  try {
    return await Promise.race([
      new Promise((resolve) => pending.push(resolve)),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Native control reply timed out while stdin remained open")), 2000); }),
    ]);
  } finally { clearTimeout(timer); }
}
const command = (id) => JSON.stringify({ id, method: "regression-unknown-operation" }) + "\n";
try {
  const ready = await next();
  assert.equal(ready.type, "ready");
  // Invalid clients must release viewer slots too. More than the admission
  // limit catches leaked entries without enumerating windows or asking for TCC.
  for (let index = 0; index < 12; index += 1) {
    const before = summaries;
    const socket = connect({ host: "127.0.0.1", port: ready.port });
    socket.on("error", () => {});
    const closed = once(socket, "close");
    socket.setTimeout(1000, () => socket.destroy());
    socket.end(randomUUID() + "\n");
    await closed;
    const deadline = Date.now() + 1500;
    while (summaries === before && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
    assert(summaries > before, "Rejected clients must release media admission slots");
  }
  // Unknown operations test dispatch without enumeration, capture, or a TCC prompt.
  const ids = Array.from({ length: 3 }, () => randomUUID());
  const first = command(ids[0]);
  child.stdin.write(first.slice(0, 9));
  await new Promise((resolve) => setTimeout(resolve, 75));
  assert.equal(received.length, 0, "A partial line must not dispatch");
  child.stdin.write(first.slice(9));
  const reply = await next();
  assert.equal(reply.type, "reply");
  assert.equal(reply.id.toLowerCase(), ids[0]);
  assert.equal(reply.error, "Unknown capture operation.");
  child.stdin.write(ids.slice(1).map(command).join(""));
  const replies = [await next(), await next()];
  assert.deepEqual(new Set(replies.map((item) => item.id.toLowerCase())), new Set(ids.slice(1)));
  assert(replies.every((item) => item.type === "reply" && item.error === "Unknown capture operation."));
  child.stdin.end();
  let timer;
  try {
    const [code] = await Promise.race([
      exited,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Native provider survived parent EOF")), 2000); }),
    ]);
    assert.equal(code, 0);
  } finally { clearTimeout(timer); }
  console.log("Native control pipe: fragmented/coalesced short commands, rejected-client cleanup and parent EOF passed");
} finally {
  lines.close();
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await exited; }
}
