import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { once } from "node:events";
import express from "express";
import vm from "node:vm";
import { webcrypto } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { buildSync } from "esbuild";
import { Pairing } from "../src/auth.js";
import { createDiagnostics, logContext } from "../src/logger.js";
import { LogStore, captureLogs, resolveLogDir } from "../src/log-store.js";
import {
  installDiagnosticsRoutes,
  logRequests,
} from "../src/diagnostics-http.js";
import {
  boundedLogEvent,
  logError,
  isLogEvent,
  MAX_LOG_EVENT_BYTES,
  type LogEvent,
} from "../../../packages/protocol/src/diagnostics.js";

function event(
  sequence: number,
  fields: Record<string, unknown> = {},
): LogEvent {
  return {
    version: 1,
    source: "vision-client",
    instanceId: "fixture",
    sequence,
    ts: new Date().toISOString(),
    monotonicMs: sequence,
    level: "info",
    component: "windows",
    event: "window.open.requested",
    fields,
  };
}
async function fixture(t: test.TestContext) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "slz-logs-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

test("scoped logging sanitizes before persistence, bounds records, and isolates concurrent actions", async (t) => {
  const directory = await fixture(t),
    diagnostics = createDiagnostics("mac-companion", { directory });
  const cycle: Record<string, unknown> = {};
  cycle.self = cycle;
  let getterInvoked = false;
  const fields = {
    token: "credential",
    url: "https://user:password@host.invalid/path?token=hidden#ticket",
    error: new Error("Bearer secret-value"),
    cycle,
  };
  diagnostics.logger("fixture").info("sanitized", fields);
  boundedLogEvent(
    event(1, {
      get unsafe() {
        getterInvoked = true;
        throw new Error("getter");
      },
    }),
  );
  const failure = Object.assign(
    new Error("original", { cause: new Error("root cause") }),
    { code: "FIXTURE" },
  );
  await Promise.all(
    ["first", "second"].map((id) =>
      logContext.run({ actionId: id, sessionId: id }, async () => {
        diagnostics.logger("fixture").info("action.started");
        await new Promise((resolve) =>
          setTimeout(resolve, id === "first" ? 10 : 1),
        );
        diagnostics.logger("nested").info("inside", {
          actionIdFromContext: logContext.current().actionId,
        });
      }),
    ),
  );
  diagnostics.logger("fixture").error("failure", { error: failure });
  const unreadable = new Proxy(
    {},
    {
      get() {
        throw new Error("unreadable");
      },
    },
  );
  diagnostics
    .logger("fixture")
    .error("unreadable", { error: logError(unreadable) });
  assert.equal(await diagnostics.store.flush(), true);
  const text = await fs.readFile(diagnostics.store.file, "utf8"),
    entries = text
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
  assert.equal(getterInvoked, false);
  for (const secret of [
    "credential",
    "user:password",
    "hidden",
    "secret-value",
  ])
    assert.ok(!text.includes(secret), secret);
  assert.equal(entries[0].fields.url, "https://host.invalid/path");
  assert.ok(entries.every(isLogEvent));
  const failed = entries.find((entry) => entry.event === "failure").fields
    .error;
  assert.equal(failed.code, "FIXTURE");
  assert.equal(failed.cause.message, "root cause");
  assert.ok(failed.stack.includes("original"));
  assert.equal(
    entries[0].fields.cycle,
    undefined,
    "Arbitrary object graphs are omitted",
  );
  const nested = entries.filter((entry) => entry.event === "inside");
  assert.equal(nested.length, 2);
  assert.notEqual(nested[0].fields.actionId, nested[1].fields.actionId);
  for (const entry of nested) {
    assert.equal(entry.fields.actionId, entry.fields.actionIdFromContext);
    assert.equal(
      entries.find(
        (other) =>
          other.event === "action.started" &&
          other.fields.sessionId === entry.fields.sessionId,
      ).fields.actionId,
      entry.fields.actionId,
    );
  }
  const oversized = boundedLogEvent(
    event(
      1,
      Object.fromEntries(
        Array.from({ length: 24 }, (_, i) => [`field${i}`, "🦄".repeat(2048)]),
      ),
    ),
  );
  assert.ok(
    Buffer.byteLength(JSON.stringify(oversized)) <= MAX_LOG_EVENT_BYTES,
  );
  assert.equal(oversized.fields.truncated, true);
  assert.ok(
    !JSON.stringify(
      boundedLogEvent({ ...event(1), unknownSecret: "discard-me" } as LogEvent),
    ).includes("discard-me"),
  );
});

test("disk ring stays bounded across writers and restarts, expires history, and reports overflow and write failures", async (t) => {
  const directory = await fixture(t);
  const options = {
    directory,
    segmentBytes: 2048,
    maxBytes: 4096,
    queueBytes: 8192,
  };
  const service = new LogStore("session-service", options);
  service.append({ ...event(1), source: "session-service" });
  await service.flush();
  for (let run = 0; run < 3; run++) {
    const store = new LogStore("mac-companion", options);
    for (let i = 1; i < 16; i++) {
      store.append(event(run * 16 + i, { note: "a".repeat(500) }));
      await store.flush();
    }
    const files = await fs.readdir(path.join(directory, "mac-companion"));
    const bytes = await Promise.all(
      files.map(
        async (file) =>
          (await fs.stat(path.join(directory, "mac-companion", file))).size,
      ),
    );
    assert.ok(bytes.reduce((sum, value) => sum + value, 0) <= options.maxBytes);
  }
  assert.ok(
    (await fs.readFile(service.file, "utf8")).includes("session-service"),
  );
  const expired = path.join(directory, "mac-companion", "1-aaaaaaaa.jsonl");
  await fs.writeFile(expired, JSON.stringify(event(999)) + "\n");
  const old = new Date(Date.now() - 25 * 60 * 60_000);
  await fs.utimes(expired, old, old);
  const restarted = new LogStore("mac-companion", options);
  restarted.append(event(1000));
  await restarted.flush();
  await assert.rejects(fs.access(expired));
  const tiny = new LogStore("mac-menu", { directory, queueBytes: 1024 });
  for (let i = 1; i < 30; i++) tiny.append(event(i));
  assert.ok(tiny.status.dropped > 0);
  await tiny.flush();
  assert.ok((await fs.readFile(tiny.file, "utf8")).includes("logs.dropped"));
  const failedDirectory = path.join(directory, "broken");
  await fs.mkdir(failedDirectory);
  await fs.writeFile(path.join(failedDirectory, "mac-companion"), "blocked");
  const failed = new LogStore("mac-companion", { directory: failedDirectory });
  failed.append(event(1));
  assert.equal(await failed.flush(), false);
  await fs.rm(path.join(failedDirectory, "mac-companion"));
  failed.append(event(2));
  assert.equal(await failed.flush(), true);
  const recovered = await fs.readFile(failed.file, "utf8");
  assert.ok(recovered.includes("logs.dropped"));
  assert.ok(recovered.includes('"sequence":2'));
});

test("capture preserves raw late/duplicate/skewed evidence, crash coverage and build identity independently of live rotation", async (t) => {
  const directory = await fixture(t),
    store = new LogStore("mac-companion", { directory });
  const around = new Date().toISOString();
  const late = {
    ...event(1),
    ts: "2026-01-01T00:00:00.000Z",
    buildId: "native-build",
  };
  store.append({ ...event(2), buildId: "native-build" });
  store.append(late);
  store.append(late);
  await store.flush();
  await fs.appendFile(store.file, '{"partial":');
  const reports = path.join(directory, "reports");
  await fs.mkdir(reports);
  const orphan = path.join(
    reports,
    "00000000-0000-0000-0000-000000000000.json.tmp",
  );
  await fs.writeFile(orphan, "unfinished capture");
  const expired = new Date(Date.now() - 8 * 24 * 60 * 60_000);
  await fs.utimes(orphan, expired, expired);
  const report = await captureLogs(directory, around, {
    hostId: "mac",
    flushIncomplete: true,
  });
  await assert.rejects(fs.access(orphan));
  await fs.rm(path.dirname(store.file), { recursive: true });
  const saved = JSON.parse(
    await fs.readFile(path.join(reports, `${report.reportId}.json`), "utf8"),
  );
  assert.equal(saved.hostId, "mac");
  assert.equal(saved.around, around);
  assert.equal(saved.flushIncomplete, true);
  assert.equal(saved.coverage.partialSegments, 1);
  assert.deepEqual(saved.coverage.unavailable, ["session-service", "mac-menu"]);
  assert.deepEqual(saved.producers, [
    { source: "vision-client", instanceId: "fixture", buildId: "native-build" },
  ]);
  assert.deepEqual(
    saved.events.map((entry: LogEvent) => entry.sequence),
    [2, 1, 1],
  );
  assert.equal(
    saved.events[1].ts,
    late.ts,
    "Incident time is a bookmark, never a device-clock filter",
  );
});

test("network ingestion requires pairing and origin checks, preserves source identity, rejects spoofing, and never logs credentials", async (t) => {
  const home = await fixture(t),
    diagnostics = createDiagnostics("mac-companion", {
      directory: path.join(home, "logs"),
    });
  const app = express(),
    pairing = new Pairing(home);
  app.use(logRequests(diagnostics));
  app.use(express.json({ limit: "128kb" }));
  pairing.install(app);
  installDiagnosticsRoutes(app, diagnostics, pairing.hostId, async () => false);
  const server = http.createServer(app);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(
    () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  );
  const base = `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`;
  const batch = {
    version: 1,
    clock: {
      observedAt: new Date().toISOString(),
      offsetMs: 100,
      uncertaintyMs: 5,
    },
    events: [
      event(1, {
        hostId: "spoofed",
        token: "secret-token",
        actionId: "fixture-action",
        ...Object.fromEntries(
          Array.from({ length: 24 }, (_, index) => [`field${index}`, index]),
        ),
        clientId: "spoofed-client",
      }),
    ],
  };
  const post = (headers: Record<string, string> = {}, body: unknown = batch) =>
    fetch(base + "/api/diagnostics/events", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
    });
  assert.equal((await post()).status, 401);
  const pair = await fetch(base + "/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: pairing.code }),
  });
  const { token } = (await pair.json()) as { token: string };
  const headers = {
    Authorization: `Bearer ${token}`,
    "X-SlopZooka-Client-ID": "native-client",
    "X-SlopZooka-Host-ID": pairing.hostId,
  };
  assert.equal(
    (await post({ ...headers, "X-SlopZooka-Host-ID": "another-mac" })).status,
    409,
    "Reassigned endpoints cannot collect another Mac's buffered logs",
  );
  assert.equal(
    (await post({ ...headers, Origin: "http://evil.invalid" })).status,
    403,
  );
  assert.equal(
    (
      await post(headers, {
        version: 1,
        events: [{ ...event(1), source: "session-service" }],
      })
    ).status,
    200,
    "Invalid records are rejected individually and acknowledged, never retried forever",
  );
  assert.equal((await post(headers)).status, 200);
  assert.equal((await post(headers)).status, 200);
  const sharedFixture = JSON.parse(
    await fs.readFile(
      new URL(
        "../../../packages/protocol/fixtures/diagnostics.v1.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.ok(isLogEvent(sharedFixture));
  assert.equal(
    (await post(headers, { version: 1, events: [sharedFixture] })).status,
    200,
    "The native bridge fixture must also satisfy the Mac intake contract",
  );
  // Exercise one incident through the actual request context and final download.
  app.post("/api/fixture-action", (_req, res) => {
    diagnostics.logger("fixture-component").error("incident.failed", {
      error: new Error("Incident root", { cause: new Error("Cause") }),
    });
    res.status(500).json({ error: "fixture" });
  });
  const action = await fetch(base + "/api/fixture-action", {
    method: "POST",
    headers: { ...headers, "X-SlopZooka-Action-ID": "fixture-action" },
  });
  const requestId = action.headers.get("X-SlopZooka-Request-ID");
  assert.equal(action.status, 500);
  const capture = await fetch(base + "/api/diagnostics/capture", {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ around: new Date().toISOString() }),
  });
  assert.equal(capture.status, 200);
  const manifest = (await capture.json()) as {
    download: string;
    flushIncomplete: boolean;
  };
  assert.equal(manifest.flushIncomplete, true);
  assert.equal((await fetch(base + manifest.download)).status, 401);
  const download = await fetch(base + manifest.download, { headers });
  assert.equal(download.status, 200);
  const report = (await download.json()) as {
    events: LogEvent[];
    producers: { buildId?: string }[];
    coverage: { missingBuilds: string[] };
  };
  const native = report.events.filter(
    (entry) => entry.source === "vision-client",
  );
  assert.equal(native.length, 2, "Raw exports retain retry identities");
  assert.equal(native[0]!.instanceId, "fixture");
  assert.equal(native[0]!.fields.hostId, pairing.hostId);
  assert.equal(native[0]!.fields.clientId, "native-client");
  assert.equal(native[0]!.clock?.uncertaintyMs, 5);
  assert.ok(native[0]!.receivedAt);
  const incident = report.events.filter(
    (entry) =>
      ["http.completed", "incident.failed"].includes(entry.event) &&
      entry.fields.actionId === "fixture-action",
  );
  assert.equal(incident.length, 2);
  assert.ok(incident.every((entry) => entry.fields.requestId === requestId));
  assert.ok(report.events.some((entry) => entry.event === "logs.rejected"));
  assert.ok(
    report.producers.some(
      (producer) => producer.buildId && producer.buildId !== "unknown",
    ),
  );
  assert.ok(
    report.coverage.missingBuilds.includes("fixture"),
    "Legacy/missing resource metadata must be explicit",
  );
  const text = await fs.readFile(diagnostics.store.file, "utf8");
  for (const secret of [token, pairing.code, "secret-token"])
    assert.ok(!text.includes(secret), secret);
  assert.ok(
    !text.includes('"route":"/api/diagnostics/events"'),
    "ingestion cannot recursively log itself",
  );
  assert.equal(
    (
      await fetch(base + "/api/diagnostics/capture", {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ around: {} }),
      })
    ).status,
    400,
  );
});

test("browser delivery works on insecure origins, bounds offline history, retries identities, and uses the native bridge", async () => {
  const bundle = buildSync({
    entryPoints: [
      fileURLToPath(new URL("../src/browser-logger.ts", import.meta.url)),
    ],
    bundle: true,
    platform: "browser",
    format: "iife",
    globalName: "diagnosticsFixture",
    write: false,
  }).outputFiles[0]!.text;
  let tick = () => {},
    online = false;
  const uploads: string[] = [],
    forwarded: LogEvent[] = [];
  const window = Object.assign(new EventTarget(), {
    webkit: undefined as
      | {
          messageHandlers: {
            diagnostics: { postMessage(event: LogEvent): void };
          };
        }
      | undefined,
  });
  const api = vm.runInNewContext(bundle + "; diagnosticsFixture", {
    window,
    TextEncoder,
    URL,
    Headers,
    AbortSignal,
    performance,
    // Match a plain-HTTP LAN origin: getRandomValues exists; randomUUID does not.
    crypto: { getRandomValues: webcrypto.getRandomValues.bind(webcrypto) },
    setInterval: (run: () => void) => {
      tick = run;
      return 1;
    },
    fetch: async (_url: string, options: RequestInit) => {
      uploads.push(String(options.body));
      return new Response("{}", { status: online ? 200 : 503 });
    },
  });
  const log = api.browserLog("fixture");
  log.debug("disabled", { detail: "should-not-be-recorded" });
  for (let index = 0; index < 2000; index++)
    log.info("offline.action", {
      index,
      note: "x".repeat(2000),
      token: "browser-secret",
    });
  const flush = async () => {
    tick();
    await new Promise((resolve) => setImmediate(resolve));
  };
  await flush();
  await flush();
  assert.equal(
    uploads[0],
    uploads[1],
    "An unavailable Mac cannot consume the browser outbox",
  );
  online = true;
  for (let index = 0; index < 20; index++) await flush();
  const events: LogEvent[] = uploads
    .slice(2)
    .flatMap((body) => JSON.parse(body).events);
  assert.ok(events.some((event) => event.event === "logs.dropped"));
  assert.ok(
    events.filter((event) => event.event === "offline.action").length < 150,
    "Offline history has a byte cap",
  );
  assert.ok(events.every(isLogEvent));
  assert.ok(events.every((event) => event.level !== "debug"));
  assert.ok(!uploads.join("").includes("browser-secret"));
  const count = uploads.length;
  await flush();
  assert.equal(
    uploads.length,
    count,
    "Uploading logs must not generate more upload logs",
  );
  window.webkit = {
    messageHandlers: {
      diagnostics: { postMessage: (event) => forwarded.push(event) },
    },
  };
  log.info("native.action");
  await flush();
  assert.equal(uploads.length, count);
  assert.equal(forwarded[0]!.event, "native.action");
});

test("restarting a writer isolates a crash tail and preserves its valid evidence", async (t) => {
  const directory = await fixture(t),
    store = new LogStore("mac-companion", { directory });
  store.append(event(1));
  await store.flush();
  await fs.appendFile(store.file, '{"crash":');
  const restarted = new LogStore("mac-companion", { directory });
  restarted.append(event(2));
  await restarted.flush();
  const entries = (await fs.readFile(restarted.file, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    entries.map((event) => event.sequence),
    [2],
    "A new process starts a clean segment",
  );
  const manifest = await captureLogs(directory);
  const report = JSON.parse(
    await fs.readFile(
      path.join(directory, "reports", `${manifest.reportId}.json`),
      "utf8",
    ),
  );
  assert.deepEqual(
    report.events.map((event: LogEvent) => event.sequence).sort(),
    [1, 2],
  );
  assert.equal(
    report.coverage.partialSegments,
    1,
    "The crash tail remains explicit in coverage",
  );
});

test("startup reserves segment capacity and bounds restart churn without per-append pruning", async (t) => {
  const directory = await fixture(t),
    role = path.join(directory, "mac-companion");
  await fs.mkdir(role);
  await Promise.all(
    Array.from({ length: 512 }, (_, index) =>
      fs.writeFile(path.join(role, `${index}-aaaaaaaa.jsonl`), "{}\n"),
    ),
  );
  const store = new LogStore("mac-companion", {
    directory,
    maxBytes: 4096,
    segmentBytes: 2048,
  });
  for (let index = 1; index <= 40; index++) {
    store.append(event(index));
    assert.equal(await store.flush(), true);
    const files = await fs.readdir(role);
    const sizes = await Promise.all(
      files.map((file) =>
        fs.stat(path.join(role, file)).then((stat) => stat.size),
      ),
    );
    assert.ok(files.length <= 512);
    assert.ok(sizes.reduce((sum, size) => sum + size, 0) <= 4096);
  }
});

test("home log directories preserve canonical isolation without an override", async (t) => {
  const directory = await fixture(t),
    home = path.join(directory, "home"),
    alias = path.join(directory, "alias");
  await fs.mkdir(home);
  await fs.symlink(home, alias);
  assert.equal(resolveLogDir(home), resolveLogDir(alias));
  assert.equal(resolveLogDir(home), path.join(await fs.realpath(home), "logs"));
  assert.notEqual(
    resolveLogDir(home),
    resolveLogDir(path.join(directory, "another-home")),
  );
});

test("capture bounds damaged segments and its exported artifact", async (t) => {
  const directory = await fixture(t),
    store = new LogStore("mac-companion", { directory });
  // Exceed the export cap with valid, bounded records, not sparse synthetic input.
  for (let batch = 0; batch < 512; batch++) {
    for (let i = 0; i < 32; i++)
      store.append(event(batch * 32 + i + 1, { note: "x".repeat(2048) }));
    await store.flush();
  }
  const damaged = path.join(directory, "session-service");
  await fs.mkdir(damaged);
  const file = await fs.open(path.join(damaged, "current.jsonl"), "w");
  await file.truncate(8 * 1024 * 1024);
  await file.close();
  const report = await captureLogs(directory);
  assert.ok(report.coverage.unavailable.includes("session-service"));
  assert.equal(report.coverage.truncated, true);
  const size = (
    await fs.stat(path.join(directory, "reports", `${report.reportId}.json`))
  ).size;
  assert.ok(size <= 32 * 1024 * 1024);
});

test("fatal errors before logger initialization survive ignored stderr in a bounded bootstrap record", async (t) => {
  const directory = await fixture(t),
    preload = path.join(directory, "bootstrap.cjs");
  buildSync({
    entryPoints: [
      fileURLToPath(
        new URL("../src/diagnostics-bootstrap.ts", import.meta.url),
      ),
    ],
    bundle: true,
    platform: "node",
    format: "cjs",
    outfile: preload,
  });
  const broken = path.join(directory, "broken.cjs");
  await fs.writeFile(
    broken,
    'throw new Error("early-import-failure Bearer bootstrap-secret");',
  );
  for (const role of ["session-service", "mac-companion"] as const) {
    for (let attempt = 0; attempt < 3; attempt++) {
      const child = spawn(
        "/usr/bin/lockf",
        [
          "-ks",
          "-t",
          "0",
          path.join(directory, "lock"),
          process.execPath,
          "--require",
          preload,
          broken,
          "unused-socket",
          "fixture-runtime",
        ],
        {
          stdio: "ignore",
          env: {
            ...process.env,
            SLOPZOOKA_DIAGNOSTICS_DIR: directory,
            SLOPZOOKA_DIAGNOSTICS_ROLE: role,
          },
        },
      );
      assert.deepEqual(await once(child, "exit"), [1, null]);
    }
    const text = await fs.readFile(
      path.join(directory, role, "bootstrap.jsonl"),
      "utf8",
    );
    const entry = JSON.parse(text);
    assert.equal(entry.source, role);
    assert.equal(entry.event, "process.bootstrap.failed");
    assert.ok(entry.fields.error.stack.includes("early-import-failure"));
    assert.ok(!text.includes("bootstrap-secret"));
    assert.ok(Buffer.byteLength(text) <= MAX_LOG_EVENT_BYTES + 1);
    assert.deepEqual(await fs.readdir(path.join(directory, role)), [
      "bootstrap.jsonl",
    ]);
  }
  const missing = spawn(
    process.execPath,
    ["--require", preload, path.join(directory, "missing-entry.cjs")],
    {
      stdio: "ignore",
      env: {
        ...process.env,
        SLOPZOOKA_DIAGNOSTICS_DIR: directory,
        SLOPZOOKA_DIAGNOSTICS_ROLE: "mac-companion",
      },
    },
  );
  assert.deepEqual(await once(missing, "exit"), [1, null]);
  const missingEntry = JSON.parse(
    await fs.readFile(
      path.join(directory, "mac-companion", "bootstrap.jsonl"),
      "utf8",
    ),
  );
  assert.equal(missingEntry.buildId, "unknown");
  assert.ok(missingEntry.fields.error.message.includes("Cannot find module"));
  const report = await captureLogs(directory);
  const saved = JSON.parse(
    await fs.readFile(
      path.join(directory, "reports", `${report.reportId}.json`),
      "utf8",
    ),
  );
  assert.equal(
    saved.events.filter((entry: LogEvent) => entry.component === "bootstrap")
      .length,
    2,
  );
});
