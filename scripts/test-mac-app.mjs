import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const app = path.join(root, "build/mac-app/SlopZooka.app");
const resources = path.join(app, "Contents/Resources");
execFileSync("codesign", ["--verify", "--deep", "--strict", app]);
const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-desktop-test-"));
const listener = http.createServer();
listener.listen(0, "127.0.0.1");
await once(listener, "listening");
const port = listener.address().port;
await new Promise((resolve) => listener.close(resolve));
const base = `http://127.0.0.1:${port}`;
await fs.mkdir(path.join(home, "workspaces"));
await fs.writeFile(
  path.join(home, "workspaces/index.json"),
  JSON.stringify([
    {
      workspaceId: "desktop-fixture",
      repo: {
        nameWithOwner: "test/project",
        owner: { login: "test" },
        name: "project",
      },
      profile: null,
      localCheckoutPath: home,
      worktreePath: home,
      branchName: "test",
      baseRef: "main",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    },
  ]),
);
const environment = {
  ...process.env,
  SLOPZOOKA_HOME: home,
  SLOPZOOKA_PORT: String(port),
  SLOPZOOKA_HOST: "127.0.0.1",
  PORTLESS_STATE_DIR: path.join(home, "portless"),
  SLOPZOOKA_LOG_DIR: home,
  SLOPZOOKA_DESKTOP: "1",
  SHELL: "/bin/sh",
  PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
};
const child = spawn(
  path.join(resources, "runtime/node"),
  [path.join(resources, "host/src/server.mjs")],
  { cwd: home, env: environment, stdio: ["pipe", "pipe", "pipe"] },
);
const exited = once(child, "exit");
let output = "",
  stderr = "";
child.stdout.on("data", (data) => {
  output += data;
});
child.stderr.on("data", (data) => {
  stderr += data;
});
async function until(fn, timeout = 12000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await fn();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out. ${stderr}`);
}
let appProcess;
let stalledPID;
const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
};
async function stop(process) {
  if (!process || process.exitCode !== null || process.signalCode !== null)
    return;
  const exited = once(process, "exit");
  process.kill("SIGTERM");
  const deadline = setTimeout(() => process.kill("SIGKILL"), 5000);
  try {
    await exited;
  } finally {
    clearTimeout(deadline);
  }
}
try {
  const frame = await until(() =>
    output.split("\n").find((line) => line.startsWith("SLZ_DESKTOP ")),
  );
  const status = JSON.parse(frame.slice("SLZ_DESKTOP ".length));
  assert.match(status.code, /^[0-9]{6}$/);
  assert.equal(status.sessions, 0);
  assert.equal(
    (await fetch(base + "/")).status,
    200,
    "bundled static assets load outside the checkout",
  );
  const paired = await (
    await fetch(base + "/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: status.code }),
    })
  ).json();
  const session = await fetch(
    base + "/api/workspaces/desktop-fixture/sessions",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${paired.token}`,
      },
      body: JSON.stringify({ sessionId: "desktop-shell", profile: null }),
    },
  );
  assert.equal(session.status, 201, await session.text());
  await until(() => output.includes('"sessions":1'));
  const logs = await fs.readFile(path.join(home, "mac-companion.log"), "utf8");
  assert.ok(!logs.includes(status.code), "pairing code stays off disk logs");
  child.stdin.end();
  assert.equal(
    (await exited)[0],
    0,
    "parent pipe loss shuts down the packaged host cleanly",
  );
  await assert.rejects(fetch(base));

  // Exercise the native supervisor with the same isolated home, not the user's live companion.
  appProcess = spawn(path.join(app, "Contents/MacOS/SlopZooka"), [], {
    cwd: home,
    env: environment,
    stdio: "ignore",
  });
  await until(async () => {
    try {
      return (await fetch(base + "/health")).ok;
    } catch {
      return false;
    }
  });
  assert.equal((await fetch(base + "/")).status, 200);
  appProcess.kill("SIGKILL"); // Simulate a UI crash: its pipe must still tear down the child.
  await once(appProcess, "exit");
  await until(async () => {
    try {
      await fetch(base + "/health");
      return false;
    } catch {
      return true;
    }
  });
  // Block Node's event loop before startup and make SIGTERM ineffective.
  // This used to leave the menu permanently stuck in Starting after its deadline.
  const stalled = path.join(home, "stalled.cjs");
  await fs.writeFile(
    stalled,
    'process.on("SIGTERM", () => {}); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);',
  );
  appProcess = spawn(path.join(app, "Contents/MacOS/SlopZooka"), [], {
    cwd: home,
    env: { ...environment, NODE_OPTIONS: `--require=${stalled}` },
    stdio: "ignore",
  });
  stalledPID = await until(() => {
    const records = execFileSync("ps", ["-axo", "pid=,ppid="], {
      encoding: "utf8",
    });
    return records
      .split("\n")
      .map((line) => line.trim().split(/\s+/).map(Number))
      .find(([, parent]) => parent === appProcess.pid)?.[0];
  });
  await until(() => !alive(stalledPID), 25000);
  assert.equal(
    appProcess.exitCode,
    null,
    "UI remains available to retry after terminating the stalled host",
  );
  console.log(
    "PASS: signed bundle, static assets, native PTY, private IPC, native startup, parent-crash shutdown, and stalled-startup escalation",
  );
} finally {
  if (stalledPID && alive(stalledPID)) process.kill(stalledPID, "SIGKILL");
  await stop(child);
  await stop(appProcess);
  await fs.rm(home, { recursive: true, force: true });
}
