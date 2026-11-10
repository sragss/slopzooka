// Native lifecycle qualification against our disposable fixture only.
// Never stops ChatGPT or the shared native helper. --cold requires both absent.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  readFile,
  writeFile,
  mkdir,
  mkdtemp,
  rm,
  realpath,
} from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { McpClient } from "@earendil-works/pi-mcp";
import { codexRuntime, isFixturePermission } from "./runtime.mjs";

const base = dirname(fileURLToPath(import.meta.url));
await mkdir(join(base, "build"), { recursive: true });
const run = await mkdtemp(join(base, "build", "native-qualification-"));
const temp = await mkdtemp(join(tmpdir(), "slz-native-check-"));
const app = join(temp, "Slz Runtime Fixture.app");
const statePath = join(temp, "state.json");
await mkdir(join(app, "Contents/MacOS"), { recursive: true });
const binary = join(app, "Contents/MacOS/SlzRuntimeFixture");
execFileSync("xcrun", [
  "swiftc",
  fileURLToPath(
    new URL("../codex-runtime-probe/Fixture.swift", import.meta.url),
  ),
  "-o",
  binary,
  "-framework",
  "AppKit",
]);
await writeFile(
  join(app, "Contents/Info.plist"),
  JSON.stringify({
    CFBundleIdentifier: "dev.slopzooka.codex-runtime-fixture",
    CFBundleExecutable: "SlzRuntimeFixture",
    CFBundleName: "Slz Runtime Fixture",
    CFBundlePackageType: "APPL",
    CFBundleVersion: "1",
    SlzFixtureStatePath: statePath,
  }),
);
execFileSync("plutil", ["-convert", "xml1", join(app, "Contents/Info.plist")]);
execFileSync("codesign", ["--force", "--sign", "-", app], {
  stdio: ["ignore", "ignore", "pipe"],
});
const executable = await realpath(binary);
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const records = [];
const sessions = [];
let ownedPid;
function processList() {
  return execFileSync("/bin/ps", ["-axo", "pid=,comm="], { encoding: "utf8" })
    .split("\n")
    .map((line) => line.trim().match(/^(\d+) (.+)$/))
    .filter(Boolean)
    .map((match) => ({ pid: Number(match[1]), command: match[2] }));
}
function sharedProcesses() {
  return processList().filter(
    (entry) =>
      entry.command === "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" ||
      entry.command.endsWith("/SkyComputerUseService"),
  );
}
async function until(fn, description, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await fn();
    if (value) return value;
    await pause(50);
  }
  throw new Error(`Timed out: ${description}`);
}
async function state() {
  try {
    return JSON.parse(await readFile(statePath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return undefined;
    throw error;
  }
}
async function launchFixture() {
  assert(
    !processList().some((entry) =>
      entry.command.endsWith("/SlzRuntimeFixture"),
    ),
    "Do not attach to or duplicate a pre-existing fixture",
  );
  await rm(statePath, { force: true });
  execFileSync("/usr/bin/open", [
    "-g",
    "-n",
    "--env",
    `SLZ_CUA_FIXTURE_STATE=${statePath}`,
    app,
  ]);
  const value = await until(state, "fixture independent state");
  ownedPid = value.pid;
  const actual = processList().find((entry) => entry.pid === ownedPid);
  assert(
    actual && (await realpath(actual.command)) === executable,
    "Fixture PID/executable mismatch",
  );
  assert.equal(value.counter, 0);
  return value;
}
async function closeFixture() {
  // Also clean up copies reopened by the native provider, even if launch did
  // not return a state file or the original PID has exited.
  for (const entry of processList().filter(
    (item) => item.command === executable || item.command === binary,
  )) {
    const pid = entry.pid;
    process.kill(pid, "SIGTERM");
    await until(
      () => !processList().some((item) => item.pid === pid),
      "owned fixture exit",
    );
  }
  ownedPid = undefined;
}
async function connect() {
  const config = await codexRuntime("computer");
  const client = new McpClient({
    name: "slz-native-qualification",
    version: "0.1.0",
    capabilities: { elicitation: {} },
    requestTimeoutMs: 15000,
  });
  client.setRequestHandler("elicitation/create", (params) => ({
    action: isFixturePermission(params) ? "accept" : "cancel",
  }));
  client.onError(() => {});
  await client.connect(config.transport);
  const tools = await client.listTools();
  assert(
    tools.some((tool) => tool.name === "js") &&
      tools.some((tool) => tool.name === "js_reset"),
  );
  const session = { client, config, pid: config.transport.pid, tools };
  sessions.push(session);
  return session;
}
async function call(session, label, code, timeoutMs = 10000) {
  const started = performance.now();
  let result;
  try {
    result = await session.client.callTool("js", {
      code,
      title: "Disposable native fixture qualification",
      timeout_ms: timeoutMs,
    });
  } catch (error) {
    result = {
      isError: true,
      content: [{ type: "text", text: error.message }],
    };
  }
  const text = (result.content ?? [])
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
  const images = (result.content ?? []).filter((part) => part.type === "image");
  // First-use guidance and app observations remain local, not vendored.
  await writeFile(join(run, `${label}.txt`), text);
  for (const [i, image] of images.entries())
    await writeFile(
      join(run, `${label}-${i}.jpg`),
      Buffer.from(image.data, "base64"),
    );
  const row = {
    label,
    elapsedMs: Math.round(performance.now() - started),
    isError: !!result.isError,
    images: images.length,
    textSha256: createHash("sha256").update(text).digest("hex"),
    error: result.isError ? text.slice(0, 1500) : undefined,
    independentState: await state(),
  };
  records.push(row);
  console.log(JSON.stringify(row));
  return { row, text };
}
const attach = `var nativeFixture = await cua.getApp(${JSON.stringify(app)});`;
const observe = "await nativeFixture.getAXStateAndScreenshot();";
const click =
  "var ax = await nativeFixture.getAXState({emit:false,disableDiffing:true}); var button = Number(ax.match(/^\\s*(\\d+) button Increment,/m)?.[1]); if (!Number.isInteger(button)) throw new Error('Fixture Increment absent'); await nativeFixture.click(button); await nativeFixture.getAXStateAndScreenshot();";
const report = {
  startedAt: new Date().toISOString(),
  requestedCold: process.argv.includes("--cold"),
  sharedBefore: sharedProcesses(),
  records,
};
try {
  if (report.requestedCold)
    assert.equal(
      report.sharedBefore.length,
      0,
      "Cold test requires ChatGPT and the shared helper to be stopped by the coordinated operator first",
    );
  await launchFixture();
  const session = await connect();
  const config = JSON.parse(
    await readFile(session.config.metadata.manifestPath, "utf8"),
  ).mcpServers.cua_repl;
  report.runtime = {
    ...session.config.metadata,
    mcpServer: session.client.serverInfo,
    protocolVersion: session.client.protocolVersion,
    manifestSha256: createHash("sha256")
      .update(await readFile(session.config.metadata.manifestPath))
      .digest("hex"),
    catalogSha256: createHash("sha256")
      .update(JSON.stringify(session.tools))
      .digest("hex"),
    toolNames: session.tools.map((tool) => tool.name),
    executablePaths: {
      command: config.command,
      node: config.env.NODE_REPL_NODE_PATH,
      helper: config.env.SKY_CUA_SERVICE_PATH,
    },
    inheritedDesktopIdentity: false,
  };
  await call(session, "initial-attach", attach);
  for (let cycle = 0; cycle < 3; cycle++) {
    if (cycle > 0) await call(session, `cycle-${cycle}-fresh-attach`, attach);
    const observation = await call(session, `cycle-${cycle}-observe`, observe);
    if (!observation.row.isError && observation.row.images > 0) {
      await call(session, `cycle-${cycle}-click-once`, click);
      const actual = await state();
      assert.equal(
        actual.counter,
        1,
        "One submitted click must produce exactly one fixture increment",
      );
    }
    await closeFixture();
    await call(session, `cycle-${cycle}-old-handle-closed`, observe);
    await closeFixture(); // observation may itself reopen the app
    await launchFixture();
    // Read only: determine whether old app handles can rebind to a new process.
    await call(session, `cycle-${cycle}-old-handle-after-relaunch`, observe);
    assert.equal(
      (await state()).counter,
      0,
      "Read-only recovery must not replay input",
    );
  }
  await session.client.close();
  const stopping = await connect();
  await call(stopping, "stop-fresh-attach", attach);
  const beforeStop = await state();
  assert.equal(beforeStop.counter, 0);
  const pending = call(
    stopping,
    "stop-in-flight-script",
    "for (var n=0; n<5; n++) { var ax = await nativeFixture.getAXState({emit:false,disableDiffing:true}); var id = Number(ax.match(/^\\s*(\\d+) button Increment,/m)?.[1]); if (!Number.isInteger(id)) throw new Error('Fixture button absent'); await nativeFixture.click(id); await new Promise(resolve => setTimeout(resolve,400)); } await nativeFixture.getAXStateAndScreenshot();",
    10000,
  );
  await until(
    async () => (await state())?.counter >= 1,
    "first native increment before Stop",
  );
  const stopAt = performance.now();
  await stopping.client.close();
  const stopAckMs = Math.round(performance.now() - stopAt);
  const atAck = await state();
  await pending;
  await pause(2500);
  const afterQuiet = await state();
  report.nativeStop = {
    stopAckMs,
    atAck,
    afterQuiet,
    additionalIncrementsAfterAck: afterQuiet.counter - atAck.counter,
    ownedMcpPidExited: !processList().some(
      (entry) => entry.pid === stopping.pid,
    ),
  };
  const recovery = await connect();
  await call(recovery, "after-stop-fresh-connection", attach);
  if (process.argv.includes("--helper-failure")) {
    assert(
      report.requestedCold,
      "Shared helper failure is only allowed inside the approved cold slot",
    );
    assert(
      !sharedProcesses().some(
        (entry) =>
          entry.command === "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
      ),
      "Desktop became active; do not interrupt its helper",
    );
    const helper = sharedProcesses().find((entry) =>
      entry.command.endsWith("/SkyComputerUseService"),
    );
    assert(helper, "Cold startup must have produced the helper");
    assert.equal(
      await realpath(helper.command),
      await realpath(
        join(
          config.env.SKY_CUA_SERVICE_PATH,
          "Contents/MacOS/SkyComputerUseService",
        ),
      ),
    );
    process.kill(helper.pid, "SIGTERM");
    await until(
      () => !processList().some((entry) => entry.pid === helper.pid),
      "approved helper exit",
    );
    const staleConnection = await call(
      recovery,
      "helper-exit-existing-connection",
      observe,
    );
    await recovery.client.close();
    const fresh = await connect();
    await call(fresh, "helper-exit-fresh-connection", attach);
    const screenshot = await call(
      fresh,
      "helper-exit-fresh-screenshot",
      observe,
    );
    const restarted = sharedProcesses().find((entry) =>
      entry.command.endsWith("/SkyComputerUseService"),
    );
    report.helperRecovery = {
      oldPid: helper.pid,
      newPid: restarted?.pid,
      existingConnectionError: staleConnection.row.isError,
      freshScreenshot: screenshot.row.images > 0 && !screenshot.row.isError,
      desktopStayedClosed: !sharedProcesses().some(
        (entry) =>
          entry.command === "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
      ),
    };
    assert(
      report.helperRecovery.freshScreenshot && restarted?.pid !== helper.pid,
    );
  }
  report.sharedAfter = sharedProcesses();
  report.completed = true;
} catch (error) {
  report.completed = false;
  report.error = error.stack;
  process.exitCode = 1;
} finally {
  for (const session of sessions) await session.client.close().catch(() => {});
  await closeFixture();
  await rm(temp, { recursive: true, force: true });
  await writeFile(join(run, "result.json"), JSON.stringify(report, null, 2));
  console.log(
    JSON.stringify({
      run,
      completed: report.completed,
      nativeStop: report.nativeStop,
      error: report.error,
    }),
  );
}
