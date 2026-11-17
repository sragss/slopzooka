import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { once } from "node:events";
import { pathToFileURL } from "node:url";
import { build } from "esbuild";
import { spawn } from "node:child_process";
import { WebSocket, WebSocketServer } from "ws";
import { SessionServiceClient } from "../src/session-service-client.js";
import { logContext } from "../src/logger.js";
import { SESSION_SERVICE_VERSION } from "../src/session-service-protocol.js";

const delay = (ms = 30) => new Promise((resolve) => setTimeout(resolve, ms));
async function until<T>(run: () => T | Promise<T>): Promise<NonNullable<T>> {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const result = await run();
    if (result) return result as NonNullable<T>;
    await delay();
  }
  throw new Error("Condition timed out");
}
function environment() {
  return {
    ...Object.fromEntries(
      Object.entries(process.env).filter(
        (entry): entry is [string, string] => entry[1] !== undefined,
      ),
    ),
    SHELL: "/bin/sh",
  };
}
async function gateway(client: SessionServiceClient) {
  const server = http.createServer();
  const sockets = new WebSocketServer({ server });
  sockets.on("connection", (ws) => {
    void client
      .relay(ws, { type: "hello", version: 1, hostId: "test" })
      .catch(() => ws.terminate());
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    url: `ws://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`,
    stop: async () => {
      for (const ws of sockets.clients) ws.terminate();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}
async function viewer(url: string) {
  const ws = new WebSocket(url);
  const messages: any[] = [];
  let output = "";
  ws.on("message", (raw) => {
    const message = JSON.parse(raw.toString());
    messages.push(message);
    if (message.type === "attached" || message.type === "output") {
      output += message.snapshot ?? message.data ?? "";
      ws.send(
        JSON.stringify({
          type: "ack",
          sessionId: message.sessionId ?? message.session.id,
          cursor: message.cursor,
        }),
      );
    }
  });
  await until(() => messages.some((message) => message.type === "hello"));
  return {
    ws,
    messages,
    output: () => output,
    attach: (cursor?: number) =>
      ws.send(
        JSON.stringify({ type: "attach", sessionId: "same-session", cursor }),
      ),
  };
}

test(
  "one service survives gateway restarts with the same PTY, screen, ownership, and deduplicated launches/input",
  { timeout: 60000 },
  async (t) => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-service-"));
    const client = await SessionServiceClient.forHome(home);
    t.after(async () => {
      await client.stop().catch(() => {});
      await fs.rm(path.dirname(client.socketPath), {
        recursive: true,
        force: true,
      });
      await fs.rm(home, { recursive: true, force: true });
    });
    const peer = await SessionServiceClient.forHome(home + "/.");
    const [first, second] = await Promise.all([
      client.connectOrStart(),
      peer.connectOrStart(),
    ]);
    assert.equal(
      first.pid,
      second.pid,
      "kernel lock chooses one service under concurrent startup",
    );
    assert.equal(
      client.logPath,
      first.logFilePath,
      "The retained service owns its diagnostic path",
    );
    const launch = {
      workspaceId: "workspace",
      cwd: home,
      profile: null,
      id: "same-session",
      environment: environment(),
    };
    const sessions = await Promise.all([
      client.create(launch),
      peer.create(launch),
    ]);
    assert.deepEqual(sessions[0], sessions[1]);
    assert.equal((await client.info()).sessions.length, 1);
    await logContext.run({ actionId: "fixture-launch" }, () =>
      client.create(launch),
    );
    assert.equal(await client.flushLogs(), true);
    const diagnostics = (await fs.readFile(client.logPath, "utf8"))
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    assert.ok(
      diagnostics.some(
        (event) =>
          event.event === "session.create.reused" &&
          event.fields.actionId === "fixture-launch",
      ),
      "The private transport preserves action identity without creating another process",
    );
    await client.rename("same-session", "  Shared terminal  ");
    const named = (await peer.info()).sessions[0];
    assert.equal(named.name, "Shared-terminal");
    assert.equal(named.title, sessions[0].title);
    let host = await gateway(client);
    t.after(async () => host.stop());
    const a = await viewer(host.url);
    const b = await viewer(host.url);
    t.after(() => {
      a.ws.terminate();
      b.ws.terminate();
    });
    assert.equal(
      a.messages.find((m) => m.type === "hello").supportsTakeControl,
      true,
    );
    a.attach();
    b.ws.send(
      JSON.stringify({ type: "take-control", sessionId: "same-session" }),
    );
    await until(() =>
      b.messages.some((m) => m.type === "error" && m.code === "403"),
    );
    b.attach();
    await until(() =>
      a.messages.some((message) => message.type === "attached"),
    );
    await until(() =>
      b.messages.some((message) => message.type === "attached"),
    );
    assert.equal(
      a.messages.find((message) => message.type === "attached").writable,
      true,
    );
    assert.equal(
      b.messages.find((message) => message.type === "attached").writable,
      false,
    );
    assert.equal(
      a.messages.find((m) => m.type === "hello").supportsInputAck,
      true,
    );
    a.ws.send(
      JSON.stringify({
        type: "input",
        sessionId: "same-session",
        data: "",
        probeId: 17,
      }),
    );
    await until(() =>
      a.messages.some((m) => m.type === "input-ack" && m.probeId === 17),
    );
    const owner = (page: typeof a) =>
      page.messages.filter((m) => m.type === "ownership").at(-1)?.writable;
    b.ws.send(
      JSON.stringify({ type: "take-control", sessionId: "same-session" }),
    );
    await until(() => owner(a) === false && owner(b) === true);
    a.ws.send(
      JSON.stringify({
        type: "input",
        sessionId: "same-session",
        data: "touch rejected-input\r",
        probeId: 18,
      }),
    );
    a.ws.send(
      JSON.stringify({
        type: "resize",
        sessionId: "same-session",
        cols: 99,
        rows: 33,
      }),
    );
    await until(
      () =>
        a.messages.filter((m) => m.type === "error" && m.code === "403")
          .length === 2,
    );
    await assert.rejects(
      fs.access(path.join(home, "rejected-input")),
      /ENOENT/,
    );
    assert.equal(
      a.messages.some((m) => m.type === "input-ack" && m.probeId === 18),
      false,
      "rejected input must never receive a PTY submission receipt",
    );
    b.ws.send(
      JSON.stringify({
        type: "resize",
        sessionId: "same-session",
        cols: 100,
        rows: 30,
      }),
    );
    await until(async () => (await client.info()).sessions[0]?.cols === 100);
    b.ws.send(
      JSON.stringify({
        type: "input",
        sessionId: "same-session",
        data: "echo $$ > takeover-pid\r",
      }),
    );
    const takeoverPID = await until(() =>
      fs.readFile(path.join(home, "takeover-pid"), "utf8").catch(() => ""),
    );
    a.ws.send(
      JSON.stringify({ type: "take-control", sessionId: "same-session" }),
    );
    await until(() => owner(a) === true && owner(b) === false);
    a.ws.terminate();
    await until(() => owner(b) === true);
    const command =
      "echo $$ > shell-pid; printf 'ONCE\\n' >> commands; printf 'BEFORE_%s\\n' RESTART";
    await client.paste("same-session", "once", command, true);
    await client.paste("same-session", "once", command, true);
    await until(() => b.output().includes("BEFORE_RESTART"));
    const pid = await until(() =>
      fs.readFile(path.join(home, "shell-pid"), "utf8").catch(() => ""),
    );
    assert.equal(
      pid,
      takeoverPID,
      "taking control preserves the same shell process",
    );
    await host.stop();
    await client.paste(
      "same-session",
      "offline",
      "printf 'WHILE_%s\\n' DISCONNECTED",
      true,
    );
    const recoveredClient = await SessionServiceClient.forHome(home);
    const recovered = await recoveredClient.connectOrStart();
    assert.equal(recovered.instanceId, first.instanceId);
    assert.equal(recovered.pid, first.pid);
    assert.equal(
      recovered.sessions[0].name,
      "Shared-terminal",
      "Names survive companion restarts with the existing session",
    );
    host = await gateway(recoveredClient);
    const c = await viewer(host.url);
    t.after(() => c.ws.terminate());
    c.attach();
    await until(() => c.output().includes("WHILE_DISCONNECTED"));
    assert.ok(c.output().includes("BEFORE_RESTART"));
    c.ws.send(
      JSON.stringify({
        type: "input",
        sessionId: "same-session",
        data: "echo $$ > shell-pid-after\r",
      }),
    );
    await until(() =>
      fs.readFile(path.join(home, "shell-pid-after"), "utf8").catch(() => ""),
    );
    assert.equal(
      await fs.readFile(path.join(home, "shell-pid-after"), "utf8"),
      pid,
    );
    assert.equal(
      await fs.readFile(path.join(home, "commands"), "utf8"),
      "ONCE\n",
    );
    // Fresh shells use current companion configuration, not daemon-startup env.
    await recoveredClient.create({
      ...launch,
      id: "fresh",
      environment: { ...environment(), SERVICE_TEST: "fresh" },
    });
    await recoveredClient.paste(
      "fresh",
      "fresh",
      "printf '%s' \"$SERVICE_TEST\" > fresh-env",
      true,
    );
    await until(() =>
      fs.readFile(path.join(home, "fresh-env"), "utf8").catch(() => ""),
    );
    assert.equal(
      await fs.readFile(path.join(home, "fresh-env"), "utf8"),
      "fresh",
    );
    await recoveredClient.end("fresh");
    await recoveredClient.end("fresh");
    await recoveredClient.stop();
    await assert.rejects(recoveredClient.info(), (error) =>
      ["ENOENT", "ECONNREFUSED"].includes(
        (error as NodeJS.ErrnoException).code ?? "",
      ),
    );
  },
);

test(
  "incompatible and unresponsive endpoints are never replaced, and socket access stays private",
  { timeout: 15000 },
  async (t) => {
    const home = await fs.mkdtemp(
      path.join(os.tmpdir(), "slz-service-incompatible-"),
    );
    const client = await SessionServiceClient.forHome(home);
    let respond = true;
    let version = 999;
    let logFilePath: string | undefined = undefined;
    let capabilities: string[] = [];
    const server = http.createServer((_req, res) => {
      if (respond)
        res.end(
          JSON.stringify({
            version,
            sessions: [{ id: "keep-me" }],
            logFilePath,
            capabilities,
          }),
        );
    });
    server.listen(client.socketPath);
    await once(server, "listening");
    t.after(async () => {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await fs.rm(path.dirname(client.socketPath), {
        recursive: true,
        force: true,
      });
      await fs.rm(home, { recursive: true, force: true });
    });
    await assert.rejects(client.connectOrStart(), /explicit update/);
    version = SESSION_SERVICE_VERSION;
    assert.equal((await client.info()).sessions[0].id, "keep-me");
    await assert.rejects(client.rename("keep-me", "Name"), /explicit update/);
    assert.equal(
      client.logPath,
      path.join(await fs.realpath(home), "session-service.log"),
    );
    assert.equal(
      await client.flushLogs(),
      false,
      "A legacy service cannot promise diagnostics coverage",
    );
    logFilePath = path.join(
      home,
      "previous-log-root",
      "session-service",
      "current.jsonl",
    );
    capabilities = ["diagnostics-v1"];
    assert.equal(
      await client.flushLogs(),
      false,
      "Retained writers outside the capture root remain incomplete",
    );
    assert.equal(
      client.logPath,
      logFilePath,
      "View Logs retains the running service's actual path",
    );
    respond = false;
    await assert.rejects(client.connectOrStart(), /timed out/);
    assert.equal(
      (await fs.stat(path.dirname(client.socketPath))).mode & 0o077,
      0,
    );
    await assert.rejects(fs.access(path.join(home, "session-runtimes")), {
      code: "ENOENT",
    });
  },
);

test(
  "a crashed service releases its kernel lock and a new instance recovers its stale socket without relaunching sessions",
  { timeout: 30000 },
  async (t) => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-service-crash-"));
    const client = await SessionServiceClient.forHome(home);
    t.after(async () => {
      await client.stop().catch(() => {});
      await fs.rm(path.dirname(client.socketPath), {
        recursive: true,
        force: true,
      });
      await fs.rm(home, { recursive: true, force: true });
    });
    const before = await client.connectOrStart();
    // No PTYs in this crash fixture; the old lockf parent reaps this exact test PID.
    process.kill(before.pid, "SIGKILL");
    await until(async () => {
      try {
        await client.info();
        return false;
      } catch {
        return true;
      }
    });
    const after = await client.connectOrStart();
    assert.notEqual(after.instanceId, before.instanceId);
    assert.notEqual(after.pid, before.pid);
    assert.deepEqual(after.sessions, []);
  },
);

test("the bounded relay accepts a large screen checkpoint without introducing another replay layer", async (t) => {
  const home = await fs.mkdtemp(
    path.join(os.tmpdir(), "slz-service-checkpoint-"),
  );
  const client = await SessionServiceClient.forHome(home);
  const server = http.createServer();
  const sockets = new WebSocketServer({ server });
  const snapshot = "x".repeat(3 * 1024 * 1024);
  sockets.on("connection", (ws) => {
    ws.send(
      JSON.stringify({
        type: "service-ready",
        version: 1,
        instanceId: "fixture",
        sessions: [],
      }),
    );
    ws.send(
      JSON.stringify({
        type: "attached",
        session: { id: "same-session" },
        cursor: 10,
        snapshot,
        writable: true,
      }),
    );
  });
  server.listen(client.socketPath);
  await once(server, "listening");
  const host = await gateway(client);
  t.after(async () => {
    await host.stop();
    for (const ws of sockets.clients) ws.terminate();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await fs.rm(path.dirname(client.socketPath), {
      recursive: true,
      force: true,
    });
    await fs.rm(home, { recursive: true, force: true });
  });
  const page = await viewer(host.url);
  t.after(() => page.ws.terminate());
  await until(() =>
    page.messages.some((message) => message.type === "attached"),
  );
  assert.equal(page.output(), snapshot);
  assert.equal(
    page.messages.find((m) => m.type === "hello").supportsInputAck,
    false,
    "retained older services must not advertise sampled PTY receipts",
  );
  assert.equal(
    page.messages.find((m) => m.type === "hello").supportsTakeControl,
    false,
    "older services remain usable without advertising takeover",
  );
});

test(
  "startup retries immediate kernel-lock contention without leaving a queued service launch",
  { timeout: 30000 },
  async (t) => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-service-lock-"));
    const client = await SessionServiceClient.forHome(home);
    const locker = spawn(
      "/usr/bin/lockf",
      [
        "-k",
        path.join(path.dirname(client.socketPath), "service.lock"),
        "/bin/sleep",
        "3",
      ],
      { stdio: "ignore" },
    );
    const released = once(locker, "exit");
    t.after(async () => {
      await released;
      await client.stop().catch(() => {});
      await fs.rm(path.dirname(client.socketPath), {
        recursive: true,
        force: true,
      });
      await fs.rm(home, { recursive: true, force: true });
    });
    await delay(100);
    const service = await client.connectOrStart();
    assert.ok(service.pid > 0);
    await released;
    await client.stop();
    await delay(300);
    await assert.rejects(client.info(), (error) =>
      ["ENOENT", "ECONNREFUSED"].includes(
        (error as NodeJS.ErrnoException).code ?? "",
      ),
    );
  },
);

test("packaged runtime damage reports the filesystem error without trying a development build", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-runtime-damage-"));
  const host = path.join(home, "host");
  let client: SessionServiceClient | undefined;
  try {
    await fs.mkdir(host);
    await fs.symlink(
      path.resolve(import.meta.dirname, "../node_modules"),
      path.join(host, "node_modules"),
      "dir",
    );
    const outfile = path.join(host, "src/client.mjs");
    await build({
      entryPoints: [
        path.resolve(import.meta.dirname, "../src/session-service-client.ts"),
      ],
      outfile,
      bundle: true,
      platform: "node",
      format: "esm",
      packages: "external",
    });
    const { SessionServiceClient: PackagedClient } = await import(
      pathToFileURL(outfile).href
    );
    client = await PackagedClient.forHome(home);
    for (const missing of ["directory", "manifest"]) {
      if (missing === "manifest")
        await fs.mkdir(path.join(home, "session-runtime"));
      await assert.rejects(
        client!.connectOrStart(),
        (error: NodeJS.ErrnoException) => {
          assert.equal(error.code, "ENOENT");
          assert.match(error.message, /session-runtime|runtime.json/);
          assert.doesNotMatch(error.message, /build-session-runtime|esbuild/);
          return true;
        },
      );
      assert.deepEqual(
        await fs.readdir(path.join(home, "session-runtimes")),
        [],
        "failed installs leave no staged runtime",
      );
    }
  } finally {
    if (client)
      await fs.rm(path.dirname(client.socketPath), {
        recursive: true,
        force: true,
      });
    await fs.rm(home, { recursive: true, force: true });
  }
});

test(
  "desktop status polls stay serial through service timeouts and recover",
  { timeout: 20000 },
  async (t) => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-status-poll-"));
    const client = await SessionServiceClient.forHome(home);
    let stalled = false,
      active = 0,
      peak = 0;
    const service = http.createServer((_req, res) => {
      active++;
      peak = Math.max(peak, active);
      res.on("close", () => active--);
      if (!stalled)
        res.end(
          JSON.stringify({
            version: 1,
            instanceId: "fixture",
            runtimeId: "fixture",
            pid: process.pid,
            sessions: [],
          }),
        );
    });
    service.listen(client.socketPath);
    await once(service, "listening");
    const listener = http.createServer();
    listener.listen(0, "127.0.0.1");
    await once(listener, "listening");
    const port = (listener.address() as import("node:net").AddressInfo).port;
    await new Promise<void>((resolve) => listener.close(() => resolve()));
    const child = spawn(
      process.execPath,
      ["--import", "tsx", "src/server.ts"],
      {
        cwd: path.resolve(import.meta.dirname, ".."),
        env: {
          ...process.env,
          SLOPZOOKA_HOME: home,
          SLOPZOOKA_PORT: String(port),
          SLOPZOOKA_HOST: "127.0.0.1",
          SLOPZOOKA_DESKTOP: "1",
          PORTLESS_STATE_DIR: home,
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    t.after(async () => {
      child.stdin.end();
      if (child.exitCode === null && child.signalCode === null)
        await once(child, "exit");
      service.closeAllConnections();
      await new Promise<void>((resolve) => service.close(() => resolve()));
      await fs.rm(path.dirname(client.socketPath), {
        recursive: true,
        force: true,
      });
      await fs.rm(home, { recursive: true, force: true });
    });
    const statuses: { sessionServiceAvailable: boolean }[] = [];
    let output = "";
    child.stderr.resume();
    child.stdout.on("data", (data) => {
      output += data;
      let end: number;
      while ((end = output.indexOf("\n")) !== -1) {
        const line = output.slice(0, end);
        output = output.slice(end + 1);
        if (line.startsWith("SLZ_DESKTOP "))
          statuses.push(JSON.parse(line.slice("SLZ_DESKTOP ".length)));
      }
    });
    await until(() => statuses.at(-1)?.sessionServiceAvailable);
    stalled = true;
    await until(() => statuses.at(-1)?.sessionServiceAvailable === false);
    assert.equal(peak, 1, "a slow status request must not overlap later ticks");
    stalled = false;
    await until(() => statuses.at(-1)?.sessionServiceAvailable);
  },
);
