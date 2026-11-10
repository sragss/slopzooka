// Explicitly authorized real terminal Codex + Pi acceptance test. Only disposable pages.
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import {
  readFile,
  writeFile,
  appendFile,
  mkdir,
  mkdtemp,
  rm,
} from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { parseArgs, parseEnv } from "node:util";
import { createInterface } from "node:readline";
import { createModels } from "@earendil-works/pi-ai";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { StdioTransport } from "@earendil-works/pi-mcp";
import { connectHarness } from "../pi-cua-probe/harness.mjs";
import { connectBridge } from "./bridge.mjs";
import { tools as catalog } from "./mcp.mjs";

const { values } = parseArgs({
  options: {
    "key-file": { type: "string" },
    codex: { type: "string", default: "codex" },
    headed: { type: "boolean", default: true },
  },
});
if (!values["key-file"])
  throw new Error("Provide --key-file PATH, not a secret");
const apiKey = parseEnv(
  await readFile(values["key-file"], "utf8"),
).OPENAI_API_KEY;
if (!apiKey) throw new Error("Selected file has no OPENAI_API_KEY");
const base = dirname(fileURLToPath(import.meta.url));
await mkdir(join(base, "build"), { recursive: true });
const run = await mkdtemp(join(base, "build", "terminal-"));
const cwd = await mkdtemp(join(tmpdir(), "slz-codex-owned-"));
const env = Object.fromEntries(
  ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"]
    .filter((key) => process.env[key])
    .map((key) => [key, process.env[key]]),
);
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const codexCommand = values.codex;
const report = {
  startedAt: new Date().toISOString(),
  cliCommand: codexCommand,
  cliVersion: execFileSync(codexCommand, ["--version"], {
    encoding: "utf8",
    env,
  }).trim(),
  checks: {},
};
const children = new Set();
let host, hostExited, connection, pi, observer;
let writes = Promise.resolve();
function record(row) {
  writes = writes.then(() =>
    appendFile(
      join(run, "journal.jsonl"),
      JSON.stringify({ at: new Date().toISOString(), ...row }) + "\n",
    ),
  );
  console.log(JSON.stringify(row));
}
async function until(fn, description, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = await fn();
    if (result) return result;
    await pause(50);
  }
  throw new Error(`Timed out: ${description}`);
}
async function fixtureEvents() {
  try {
    const text = await readFile(
      join(connection.artifacts, "fixture-events.jsonl"),
      "utf8",
    );
    return text
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}
function compact(value, images) {
  if (Array.isArray(value)) return value.map((entry) => compact(entry, images));
  if (!value || typeof value !== "object") return value;
  if (value.type === "image" && typeof value.data === "string") {
    images.push({ data: value.data, mimeType: value.mimeType });
    return {
      type: "image",
      mimeType: value.mimeType,
      base64Bytes: value.data.length,
    };
  }
  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [key, compact(entry, images)]),
  );
}
function startCodex(label, prompt) {
  const rows = [];
  const images = [];
  const args = [
    "exec",
    "--ignore-user-config",
    "--ephemeral",
    "--json",
    "--sandbox",
    "read-only",
    "--skip-git-repo-check",
    "--cd",
    cwd,
    "-c",
    "features.shell_tool=false",
    "-c",
    "features.apps=false",
    "-c",
    "features.plugins=false",
    "-c",
    'web_search="disabled"',
    "-c",
    'approval_policy="never"',
    "-c",
    `mcp_servers.owned_browser.command=${JSON.stringify(connection.mcp.command)}`,
    "-c",
    `mcp_servers.owned_browser.args=${JSON.stringify(connection.mcp.args)}`,
    // User authorized these disposable fixture actions. This invocation grants
    // only our origin-restricted server; it does not persist general MCP trust.
    "-c",
    'mcp_servers.owned_browser.default_tools_approval_mode="approve"',
    "-c",
    "mcp_servers.owned_browser.required=true",
    "-c",
    "mcp_servers.owned_browser.startup_timeout_sec=20",
    "-c",
    "mcp_servers.owned_browser.tool_timeout_sec=20",
    "-",
  ];
  const child = spawn(codexCommand, args, {
    cwd,
    env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.add(child);
  const started = performance.now();
  let stderr = "";
  const done = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      children.delete(child);
      resolve({
        code,
        signal,
        elapsedMs: Math.round(performance.now() - started),
      });
    });
  });
  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    try {
      const row = compact(JSON.parse(line), images);
      rows.push(row);
      writes = writes.then(() =>
        appendFile(
          join(run, `${label}-events.jsonl`),
          JSON.stringify(row) + "\n",
        ),
      );
    } catch {
      /* Preserve non-JSON diagnostics separately, never treat them as tool success. */ stderr +=
        line + "\n";
    }
  });
  child.stderr.on("data", (data) => {
    stderr += data;
  });
  child.stdin.end(
    `This is a user-authorized disposable SlopZooka browser integration test. Use only the owned_browser MCP tools and the exact fixture URLs below. Do not use shell, files, other MCP servers, built-in browser, desktop CUA or other agents. Follow the MCP guidance. Do not retry uncertain mutations. Stop and report any initialization/access error. ${prompt}`,
  );
  return {
    child,
    rows,
    images,
    async finish() {
      const outcome = await done;
      await writeFile(join(run, `${label}-stderr.txt`), stderr);
      for (const [index, image] of images.entries())
        await writeFile(
          join(run, `${label}-${index}.jpg`),
          Buffer.from(image.data, "base64"),
        );
      await writes;
      return { ...outcome, rows, imageCount: images.length };
    },
  };
}
function verifyEvents(rows, path, label) {
  const relevant = rows.filter((row) => row.fixture === path);
  assert.deepEqual(
    relevant.map((row) => row.action),
    ["save", "increment", "increment", "settings"],
  );
  assert(relevant.every((row) => row.label === label));
  assert.equal(relevant.at(-1).count, 2);
  return relevant;
}

try {
  host = spawn(
    process.execPath,
    [
      join(base, "probe.mjs"),
      "--serve",
      ...(values.headed ? ["--headed"] : []),
    ],
    { cwd: base, env, stdio: ["ignore", "pipe", "pipe"] },
  );
  hostExited = new Promise((resolve) =>
    host.once("exit", (code, signal) => resolve({ code, signal })),
  );
  host.stderr.on("data", (data) => {
    writes = writes.then(() => appendFile(join(run, "host-stderr.txt"), data));
  });
  createInterface({ input: host.stdout }).on("line", (line) => {
    try {
      const row = JSON.parse(line);
      if (row.kind === "serve-ready") connection = row;
    } catch {
      /* startup logs are not the connection record */
    }
  });
  await until(() => connection, "disposable browser host");
  observer = await connectBridge(connection.mcp.args[1]);
  const models = createModels();
  models.setProvider(openaiProvider());
  const piEvents = [];
  pi = await connectHarness({
    transport: new StdioTransport({
      ...connection.mcp,
      env,
      inheritEnv: false,
    }),
    model: models.getModel("openai", "gpt-6.1-sol"),
    toolNames: catalog.map((tool) => tool.name),
    maxToolCalls: 30,
    streamFn: (model, context, options) =>
      models.streamSimple(model, context, {
        ...options,
        apiKey,
        reasoning: "low",
        maxTokens: 2048,
        maxRetries: 0,
      }),
    onEvent: (event) =>
      piEvents.push({ at: new Date().toISOString(), ...event }),
  });
  const task = (path, label) =>
    `Open ${connection.fixtureOrigin}/${path} in a background tab, observe it, fill Workspace label with ${label}, save it, click Increment exactly twice, and open Settings. Verify Counter: 2, label and Settings with a fresh observation and a screenshot. Leave the tab open. Complete in at most 15 tool calls and report the observed result.`;
  record({ stage: "ready", run, cliVersion: report.cliVersion });
  const codex = startCodex("codex", task("codex", "terminal-codex"));
  const timeout = setTimeout(() => codex.child.kill("SIGINT"), 180000);
  const outcomes = await Promise.allSettled([
    codex.finish(),
    pi.agent.prompt(task("pi-peer", "pi-peer")),
  ]);
  clearTimeout(timeout);
  await writeFile(
    join(run, "pi-events.json"),
    JSON.stringify(piEvents, null, 2),
  );
  for (const outcome of outcomes)
    if (outcome.status === "rejected") throw outcome.reason;
  const cli = outcomes[0].value;
  assert.equal(
    cli.code,
    0,
    "Real Codex CLI did not complete successfully; inspect its local diagnostics",
  );
  const actions = cli.rows.filter((row) => row.item?.type === "mcp_tool_call");
  const completed = actions.filter((row) => row.type === "item.completed");
  assert(completed.length > 0, "No actual Codex MCP tool calls recorded");
  assert(
    completed.every(
      (row) => row.item.status === "completed" && !row.item.error,
    ),
    "Codex tool failed; inspect its exact returned error",
  );
  assert(
    completed.every((row) => row.item.server === "owned_browser"),
    "Codex used an unexpected server",
  );
  assert(
    completed.some((row) => row.item.tool === "browser_screenshot"),
    "Codex did not request a screenshot",
  );
  assert(cli.imageCount > 0, "Codex must receive actual image content");
  const rows = await fixtureEvents();
  const piImages = pi.agent.state.messages
    .filter((message) => message.role === "toolResult")
    .flatMap((message) =>
      message.content.filter((part) => part.type === "image"),
    );
  assert(piImages.length > 0);
  await writeFile(
    join(run, "pi-peer.jpg"),
    Buffer.from(piImages.at(-1).data, "base64"),
  );
  report.checks.concurrentCompletion = {
    codex: {
      exitCode: cli.code,
      elapsedMs: cli.elapsedMs,
      toolCalls: completed.length,
      images: cli.imageCount,
      events: verifyEvents(rows, "/codex", "terminal-codex"),
    },
    pi: {
      images: piImages.length,
      events: verifyEvents(rows, "/pi-peer", "pi-peer"),
    },
  };
  await until(
    async () =>
      !(await observer.call("browser_tabs")).find((tab) =>
        tab.url.endsWith("/codex"),
      )?.claimed,
    "Codex completion releases lease",
  );
  assert(
    (await observer.call("browser_tabs")).find((tab) =>
      tab.url.endsWith("/pi-peer"),
    )?.claimed,
  );
  report.checks.codexExitReleasedOnlyItsLease = true;
  record({ stage: "concurrent-completion", ...report.checks });

  const interrupt = startCodex(
    "codex-interrupt",
    `Open ${connection.fixtureOrigin}/codex-interrupt, observe it, and click Increment 30 times using a separate browser_click tool call for each click. This disposable counter is a cancellation fixture. Do not batch calls or use scripts. Stop if interrupted. Do not close or release the tab.`,
  );
  const interruptDeadline = setTimeout(
    () => interrupt.child.kill("SIGINT"),
    120000,
  );
  await until(
    async () =>
      (await fixtureEvents()).some(
        (row) =>
          row.fixture === "/codex-interrupt" && row.action === "increment",
      ),
    "first real Codex action before interrupt",
    90000,
  );
  const requestedAt = performance.now();
  interrupt.child.kill("SIGINT");
  const interrupted = await interrupt.finish();
  clearTimeout(interruptDeadline);
  await until(
    async () =>
      !(await observer.call("browser_tabs")).find((tab) =>
        tab.url.endsWith("/codex-interrupt"),
      )?.claimed,
    "interrupted Codex lease release",
  );
  const afterRelease = (await fixtureEvents()).filter(
    (row) => row.fixture === "/codex-interrupt",
  );
  await pause(1000);
  assert.equal(
    (await fixtureEvents()).filter((row) => row.fixture === "/codex-interrupt")
      .length,
    afterRelease.length,
  );
  assert(
    afterRelease.length < 30,
    "Interrupt failed to stop the bounded test before completion",
  );
  report.checks.realCodexInterrupt = {
    exitCode: interrupted.code,
    signal: interrupted.signal,
    observedThroughQuietPeriodMs: Math.round(performance.now() - requestedAt),
    completedIncrements: afterRelease.length,
    leaseReleased: true,
    noInputAfterReleaseInOneSecond: true,
  };
  await pi.agent.prompt(
    "Continue on your already owned /pi-peer tab. Observe it again, increment once, verify Counter: 3 and capture a screenshot. Do not open, claim or control any other tab.",
  );
  const continued = (await fixtureEvents()).filter(
    (row) => row.fixture === "/pi-peer",
  );
  assert.equal(continued.at(-1).count, 3);
  report.checks.piContinuedAfterCodexInterrupt = true;
  record({
    stage: "interrupt-and-peer-continuation",
    result: report.checks.realCodexInterrupt,
    piContinued: true,
  });
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = error.stack;
  process.exitCode = 1;
  record({ stage: "failed", error: error.message });
} finally {
  for (const child of children) child.kill("SIGINT");
  await pi?.stop();
  observer?.close();
  if (host && host.exitCode === null) host.kill("SIGINT");
  report.hostCleanup = await hostExited;
  await writes;
  await rm(cwd, { recursive: true, force: true });
  await writeFile(join(run, "result.json"), JSON.stringify(report, null, 2));
  console.log(
    JSON.stringify({
      run,
      passed: report.passed,
      checks: Object.keys(report.checks),
      hostCleanup: report.hostCleanup,
    }),
  );
}
