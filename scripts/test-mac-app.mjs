import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import { X509Certificate } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const app =
  process.env.SLOPZOOKA_TEST_APP ??
  path.join(root, "build/mac-app/SlopZooka.app");
const resources = path.join(app, "Contents/Resources");
const { WebSocket } = createRequire(path.join(resources, "host/package.json"))(
  "ws",
);
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
  SLOPZOOKA_DESKTOP: "1",
  SHELL: "/bin/sh",
  PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
  NO_COLOR: "1",
  COLORTERM: "",
  SLOPZOOKA_CODEX_COMMAND:
    `printf 'COLOR_ENV=%s/%s/%s\\n' "$TERM" "$COLORTERM" "\${NO_COLOR-unset}"; ` +
    `printf '\\033[31mRED\\033[0m \\033[38;5;202mINDEXED\\033[0m \\033[38;2;12;120;240mRGB\\033[0m\\n'`,
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
let sessionSocketPath;
async function serviceControl(route, method = "GET") {
  if (!sessionSocketPath) return;
  return new Promise((resolve, reject) => {
    const request = http.request(
      { socketPath: sessionSocketPath, path: route, method, agent: false },
      (response) => {
        let body = "";
        response.on("data", (chunk) => {
          body += chunk;
        });
        response.on("end", () => resolve(JSON.parse(body)));
        response.on("error", reject);
      },
    );
    request.setTimeout(5000, () =>
      request.destroy(new Error("Service control timed out")),
    );
    request.on("error", reject);
    request.end();
  });
}
let appProcess;
let stalledPID;
let colorViewer;
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
  sessionSocketPath = status.sessionSocketPath;
  assert.ok(
    sessionSocketPath,
    "private status identifies the isolated service endpoint",
  );
  const health = await (await fetch(base + "/health")).json();
  assert.equal(
    status.sessionLogPath,
    path.join(
      path.dirname(path.dirname(health.logFilePath)),
      "session-service",
      "current.jsonl",
    ),
  );
  await until(async () => {
    try {
      await fs.access(status.sessionLogPath);
      return true;
    } catch {
      return false;
    }
  });
  assert.match(status.code, /^[0-9]{6}$/);
  assert.equal(status.sessions, 0);
  assert.equal(
    (await fetch(base + "/")).status,
    200,
    "bundled static assets load outside the checkout",
  );
  const display = await fetch(base + "/api/pair/display", { method: "POST" });
  assert.deepEqual(
    await display.json(),
    { ok: true },
    "display request never returns the code",
  );
  await until(() =>
    output
      .split("\n")
      .filter((line) => line.startsWith("SLZ_DESKTOP "))
      .some(
        (line) =>
          JSON.parse(line.slice("SLZ_DESKTOP ".length)).pairingDisplayUntil >
          Date.now(),
      ),
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
  // Exercise the shipped host, not just source tests: stale bundles can still
  // leak automation's NO_COLOR into actual agents even when source tests pass.
  colorViewer = new WebSocket(base.replace("http:", "ws:") + "/ws", {
    headers: { Authorization: `Bearer ${paired.token}` },
  });
  let terminalOutput = "";
  colorViewer.on("message", (data) => {
    const message = JSON.parse(data);
    if (message.type === "attached") terminalOutput += message.snapshot ?? "";
    if (message.type === "output") terminalOutput += message.data;
    if (message.type === "attached" || message.type === "output")
      colorViewer.send(
        JSON.stringify({
          type: "ack",
          sessionId: "desktop-colors",
          cursor: message.cursor,
        }),
      );
  });
  await once(colorViewer, "open");
  const colorSession = await fetch(
    base + "/api/workspaces/desktop-fixture/sessions",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${paired.token}`,
      },
      body: JSON.stringify({ sessionId: "desktop-colors", profile: "codex" }),
    },
  );
  assert.equal(colorSession.status, 201, await colorSession.text());
  colorViewer.send(
    JSON.stringify({ type: "attach", sessionId: "desktop-colors" }),
  );
  await until(() => terminalOutput.includes("RGB"));
  assert.ok(
    terminalOutput.includes("COLOR_ENV=xterm-256color/truecolor/unset"),
    terminalOutput,
  );
  assert.ok(terminalOutput.includes("\x1b[31mRED"), terminalOutput);
  assert.ok(terminalOutput.includes("\x1b[38;5;202mINDEXED"), terminalOutput);
  assert.ok(
    terminalOutput.includes("\x1b[38;2;12;120;240mRGB"),
    terminalOutput,
  );
  colorViewer.close();
  const apiHeaders = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${paired.token}`,
  };
  const savedPreview = await fetch(base + "/api/frontends", {
    method: "POST",
    headers: apiHeaders,
    body: JSON.stringify({ url: "https://127.0.0.1:1" }),
  });
  assert.equal(savedPreview.status, 201);
  const { frontend } = await savedPreview.json();
  const openedPreview = await fetch(base + "/api/frontends/open", {
    method: "POST",
    headers: apiHeaders,
    body: JSON.stringify({ id: frontend.id }),
  });
  assert.equal(openedPreview.status, 200);
  const preview = await openedPreview.json();
  assert.equal(preview.gatewayScheme, "https");
  await new Promise((resolve, reject) => {
    const request = https.get(
      `https://127.0.0.1:${preview.exposedPort}/__slz_access?token=${preview.accessToken}`,
      {
        ca: new X509Certificate(
          Buffer.from(preview.certificateAuthority, "base64"),
        ).toString(),
      },
      (response) => {
        response.resume();
        try {
          assert.equal(response.statusCode, 303);
          assert.match(response.headers["set-cookie"][0], /; Secure/);
          resolve();
        } catch (error) {
          reject(error);
        }
      },
    );
    request.setTimeout(5000, () =>
      request.destroy(new Error("Packaged TLS gateway timed out")),
    );
    request.on("error", reject);
  });
  // Opening from the native app uses private IPC, never the public pairing PIN.
  child.stdin.write(
    JSON.stringify({ type: "open-dashboard", requestId: "desktop-open" }) +
      "\n",
  );
  const dashboardFrame = await until(() =>
    output.split("\n").find((line) => line.startsWith("SLZ_DASHBOARD ")),
  );
  const dashboardReply = JSON.parse(
    dashboardFrame.slice("SLZ_DASHBOARD ".length),
  );
  assert.equal(dashboardReply.requestId, "desktop-open");
  const dashboardURL = new URL(dashboardReply.url);
  assert.equal(dashboardURL.origin, `http://localhost:${port}`);
  assert.equal(dashboardURL.search, "");
  const ticket = new URLSearchParams(dashboardURL.hash.slice(1)).get("connect");
  assert.match(ticket, /^[a-f0-9]{64}$/);
  const signIn = await fetch(dashboardURL.origin + "/api/pair/dashboard", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Origin: dashboardURL.origin,
    },
    body: JSON.stringify({ ticket }),
  });
  assert.equal(signIn.status, 200, await signIn.text());
  const dashboardCookie = signIn.headers.get("set-cookie").split(";")[0];
  assert.equal(
    (
      await fetch(base + "/api/sessions", {
        headers: { Cookie: dashboardCookie },
      })
    ).status,
    200,
  );
  child.stdin.write(
    JSON.stringify({
      type: "open-dashboard",
      requestId: "desktop-report",
      reportBug: true,
    }) + "\n",
  );
  const reportFrame = await until(() =>
    output.split("\n").find((line) => {
      if (!line.startsWith("SLZ_DASHBOARD ")) return false;
      return (
        JSON.parse(line.slice("SLZ_DASHBOARD ".length)).requestId ===
        "desktop-report"
      );
    }),
  );
  const reportLink = new URL(
    JSON.parse(reportFrame.slice("SLZ_DASHBOARD ".length)).url,
  );
  assert.equal(reportLink.pathname, "/report-bug");
  assert.ok(new URLSearchParams(reportLink.hash.slice(1)).has("connect"));
  const reportPage = await fetch(base + "/report-bug");
  assert.equal(reportPage.status, 200);
  assert.ok((await reportPage.text()).includes("Logs stay on your Mac"));
  for (const asset of ["bug-report.js", "bug-report.css"])
    assert.equal((await fetch(base + "/" + asset)).status, 200);
  const logs = await fs.readFile(health.logFilePath, "utf8");
  assert.ok(!logs.includes(status.code), "pairing code stays off disk logs");
  // A running service must not depend on files being retained in the old .app.
  const runtime = path.join(resources, "session-runtime");
  const heldRuntime = path.join(home, "old-bundle-runtime");
  await fs.rename(runtime, heldRuntime);
  try {
    const replacementShell = await fetch(
      base + "/api/workspaces/desktop-fixture/sessions",
      {
        method: "POST",
        headers: apiHeaders,
        body: JSON.stringify({ sessionId: "after-replacement", profile: null }),
      },
    );
    assert.equal(replacementShell.status, 201, await replacementShell.text());
    await fetch(base + "/api/sessions/after-replacement/input", {
      method: "POST",
      headers: apiHeaders,
      body: JSON.stringify({
        commandId: "before",
        text: "echo $$ > survivor-pid",
        sendReturn: true,
      }),
    });
    await until(() =>
      fs.readFile(path.join(home, "survivor-pid"), "utf8").catch(() => ""),
    );
  } finally {
    await fs.rename(heldRuntime, runtime);
  }
  const survivorPID = await fs.readFile(
    path.join(home, "survivor-pid"),
    "utf8",
  );
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
  // Capture includes collected evidence; it cannot flush another process's
  // in-memory outbox. Wait for the menu's independent disk writer first.
  const menuDirectory = path.join(
    path.dirname(path.dirname(health.logFilePath)),
    "mac-menu",
  );
  await until(async () => {
    const files = await fs.readdir(menuDirectory).catch(() => []);
    const contents = await Promise.all(
      files.map((file) =>
        fs.readFile(path.join(menuDirectory, file), "utf8").catch(() => ""),
      ),
    );
    return contents.some((text) => text.endsWith("\n"));
  });
  const manifest = await (
    await fetch(base + "/api/diagnostics/capture", {
      method: "POST",
      headers: apiHeaders,
    })
  ).json();
  const report = await (
    await fetch(base + manifest.download, { headers: apiHeaders })
  ).json();
  for (const source of ["mac-companion", "session-service", "mac-menu"])
    assert.ok(
      report.events.some((event) => event.source === source),
      `${source} shares the reported log root and appears in captures`,
    );

  await fetch(base + "/api/sessions/after-replacement/input", {
    method: "POST",
    headers: apiHeaders,
    body: JSON.stringify({
      commandId: "after",
      text: "echo $$ > survivor-pid-after",
      sendReturn: true,
    }),
  });
  await until(() =>
    fs.readFile(path.join(home, "survivor-pid-after"), "utf8").catch(() => ""),
  );
  assert.equal(
    await fs.readFile(path.join(home, "survivor-pid-after"), "utf8"),
    survivorPID,
    "native relaunch reconnects to the same PTY after parent-pipe shutdown",
  );
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
  assert.ok(
    (await serviceControl("/info")).sessions.some(
      (session) => session.id === "after-replacement",
    ),
    "UI crash stops its HTTP child but retains the service and terminals",
  );
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
    "PASS: signed bundle, PTY survival across app replacement and UI/HTTP restarts, private IPC sign-in, HTTPS preview, and stalled-startup escalation",
  );
} finally {
  colorViewer?.terminate();
  if (stalledPID && alive(stalledPID)) process.kill(stalledPID, "SIGKILL");
  await stop(child);
  await stop(appProcess);
  if (sessionSocketPath) {
    await serviceControl("/stop", "POST").catch(() => {});
    await until(async () => {
      try {
        await serviceControl("/info");
        return false;
      } catch {
        return true;
      }
    }, 5000).catch(() => {});
    await fs.rm(path.dirname(sessionSocketPath), {
      recursive: true,
      force: true,
    });
  }
  await fs.rm(home, { recursive: true, force: true });
}
