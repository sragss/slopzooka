import test from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import https from "node:https";
import { once } from "node:events";
import { WebSocket, WebSocketServer } from "ws";
import { FrontendService } from "../src/frontends.js";
import { isClientMessage } from "../../../packages/protocol/src/index.js";

const delay = (ms = 30) => new Promise((r) => setTimeout(r, ms));
async function until<T>(
  fn: () => T | Promise<T>,
  timeout = 6000,
): Promise<NonNullable<T>> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = await fn();
    if (result) return result as NonNullable<T>;
    await delay();
  }
  throw new Error("Condition timed out");
}
async function listen(server: http.Server) {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return (server.address() as import("node:net").AddressInfo).port;
}
const logger = {
  info() {},
  warn() {},
  error() {},
  logDir: "",
  logFilePath: "",
};

test("protocol rejects malformed dimensions, identifiers, payloads and versions", () => {
  for (const value of [
    null,
    {},
    { type: "hello", version: 2 },
    { type: "input", sessionId: "x", data: 1 },
    { type: "resize", sessionId: "x", cols: Infinity, rows: 40 },
    { type: "resize", sessionId: "x", cols: 999999, rows: 40 },
    { type: "ack", sessionId: "../x", cursor: 1 },
    { type: "input", sessionId: "x", data: "x".repeat(65537) },
  ])
    assert.equal(isClientMessage(value), false);
  assert.equal(
    isClientMessage({
      type: "resize",
      sessionId: "session-1",
      cols: 120,
      rows: 40,
    }),
    true,
  );
});

test(
  "host sessions survive disconnection, restore screens, isolate viewers, and deduplicate input",
  { timeout: 30000 },
  async () => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-integration-"));
    const placeholder = http.createServer();
    const port = await listen(placeholder);
    await new Promise<void>((r) => placeholder.close(() => r()));
    const worktree = path.join(home, "project");
    await fs.mkdir(worktree);
    await fs.mkdir(path.join(home, "workspaces"));
    const record = {
      clusterId: "workspace-1",
      repo: {
        nameWithOwner: "test/project",
        owner: { login: "test" },
        name: "project",
      },
      profile: null,
      localCheckoutPath: worktree,
      worktreePath: worktree,
      branchName: "test",
      baseRef: "main",
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    await fs.writeFile(
      path.join(home, "workspaces", "index.json"),
      JSON.stringify([record]),
    );
    const child = spawn(
      process.execPath,
      ["--import", "tsx", "src/server.ts"],
      {
        cwd: path.resolve(import.meta.dirname, ".."),
        env: {
          ...process.env,
          SLOPZOOKA_HOME: home,
          SLOPZOOKA_LOG_DIR: home,
          SLOPZOOKA_HOST: "127.0.0.1",
          SLOPZOOKA_PORT: String(port),
          PORTLESS_STATE_DIR: path.join(home, "portless"),
          SHELL: "/bin/sh",
        },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let output = "";
    child.stdout.on("data", (d) => {
      output += d;
    });
    child.stderr.on("data", (d) => {
      output += d;
    });
    const base = `http://127.0.0.1:${port}`;
    const sockets: WebSocket[] = [];
    let shutdownChildPID: number | undefined;
    let token = "";
    const api = async (
      route: string,
      body?: unknown,
      method = body ? "POST" : "GET",
    ) => {
      const response = await fetch(base + route, {
        method,
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      return { status: response.status, body: await response.json() };
    };
    const connect = async () => {
      const ws = new WebSocket(base.replace("http:", "ws:") + "/ws", {
        headers: { Authorization: `Bearer ${token}`, Origin: base },
      });
      sockets.push(ws);
      const messages: any[] = [];
      ws.on("message", (d) => messages.push(JSON.parse(d.toString())));
      await once(ws, "open");
      await until(() => messages.find((m) => m.type === "hello"));
      return { ws, messages, send: (m: unknown) => ws.send(JSON.stringify(m)) };
    };
    try {
      const code = await until(
        () => output.match(/pairing code: ([a-f0-9]+)/)?.[1],
      );
      await until(async () => {
        try {
          return (await fetch(base + "/health")).ok;
        } catch {
          return false;
        }
      });
      assert.equal((await api("/api/sessions")).status, 401);
      const favicon = await fetch(base + "/favicon.png");
      assert.equal(favicon.status, 200, "favicon is available before pairing");
      assert.match(favicon.headers.get("content-type") ?? "", /image\/png/);
      assert.equal(
        Buffer.from(await favicon.arrayBuffer())
          .subarray(0, 8)
          .toString("hex"),
        "89504e470d0a1a0a",
      );
      const dashboardStyle = await fetch(base + "/harness.css");
      assert.equal(
        dashboardStyle.status,
        200,
        "pairing page styles are public",
      );
      assert.match(
        dashboardStyle.headers.get("content-type") ?? "",
        /text\/css/,
      );
      assert.equal(
        (await api("/api/sessions/missing.js", undefined, "DELETE")).status,
        401,
        "an API path ending in .js is not a public asset",
      );
      const badOrigin = await fetch(base + "/api/pair", {
        method: "POST",
        headers: {
          Origin: "http://evil.local",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ code }),
      });
      assert.equal(badOrigin.status, 403);
      token = (await api("/api/pair", { code })).body.token;
      assert.ok(token);
      assert.equal(
        (await api("/api/frontends", { url: "file:///etc/passwd" })).status,
        400,
      );
      const savedFrontend = await api("/api/frontends", {
        url: "https://example.invalid/preview",
      });
      assert.equal(savedFrontend.status, 201);
      const frontendID = savedFrontend.body.frontend.id;
      const openedFrontend = await api("/api/frontends/open", {
        id: frontendID,
      });
      assert.equal(openedFrontend.status, 200);
      assert.equal(openedFrontend.body.frontend.transport, "direct");
      assert.equal(
        (await api(`/api/frontends/${frontendID}`, undefined, "DELETE")).status,
        200,
      );
      assert.equal(
        (await api("/api/frontends/open", { id: frontendID })).status,
        404,
      );
      assert.equal(
        (
          await api("/api/sessions/missing/input", {
            commandId: "one",
            text: "x",
            sendReturn: true,
          })
        ).status,
        404,
      );
      const create = () =>
        api("/api/workspaces/workspace-1/sessions", {
          sessionId: "terminal-1",
          profile: null,
        });
      // The server can create a session even when its response never reaches the client.
      const abandoned = await fetch(
        base + "/api/workspaces/workspace-1/sessions",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
            Origin: base,
          },
          body: JSON.stringify({ sessionId: "terminal-1", profile: null }),
        },
      );
      await abandoned.body?.cancel();
      const launches = await Promise.all([create(), create()]);
      assert.deepEqual(
        launches.map((r) => r.status),
        [201, 201],
      );
      await api("/api/workspaces/workspace-1/sessions", {
        sessionId: "terminal-2",
        profile: null,
      });
      assert.equal((await api("/api/sessions")).body.sessions.length, 2);
      const first = await connect();
      assert.equal(first.messages[0].sessions.length, 2);
      first.send({ type: "attach", sessionId: "terminal-1" });
      const attached = await until(() =>
        first.messages.find((m) => m.type === "attached"),
      );
      assert.equal(attached.writable, true);
      first.send({
        type: "ack",
        sessionId: "terminal-1",
        cursor: attached.cursor,
      });
      const reader = await connect();
      reader.send({ type: "attach", sessionId: "terminal-1" });
      assert.equal(
        (await until(() => reader.messages.find((m) => m.type === "attached")))
          .writable,
        false,
      );
      reader.send({
        type: "input",
        sessionId: "terminal-1",
        data: "echo should-not-run\r",
      });
      assert.equal(
        (await until(() => reader.messages.find((m) => m.type === "error")))
          .code,
        "403",
      );
      const command = {
        commandId: "write-once",
        text: "printf 'once\\n' >> marker; echo $$ > pid; printf '\\033[?1049hSCREEN-CHECKPOINT'",
        sendReturn: true,
      };
      assert.equal(
        (await api("/api/sessions/terminal-1/input", command)).status,
        200,
      );
      assert.equal(
        (await api("/api/sessions/terminal-1/input", command)).status,
        200,
      );
      await until(async () => {
        try {
          return (
            (await fs.readFile(path.join(worktree, "marker"), "utf8")) ===
            "once\n"
          );
        } catch {
          return false;
        }
      });
      assert.equal(
        (
          await api("/api/sessions/terminal-1/input", {
            ...command,
            text: "different",
          })
        ).status,
        409,
      );
      await until(() =>
        first.messages.some(
          (m) => m.type === "output" && m.data.includes("SCREEN-CHECKPOINT"),
        ),
      );
      const pid = Number(await fs.readFile(path.join(worktree, "pid"), "utf8"));
      first.ws.close();
      await once(first.ws, "close");
      reader.ws.close();
      await once(reader.ws, "close");
      process.kill(pid, 0);
      assert.equal(
        (await api("/api/sessions")).body.sessions.filter(
          (s: any) => s.status === "running",
        ).length,
        2,
      );
      const restored = await connect();
      restored.send({ type: "attach", sessionId: "terminal-1" });
      const checkpoint = await until(() =>
        restored.messages.find((m) => m.type === "attached"),
      );
      assert.ok(checkpoint.snapshot.includes("SCREEN-CHECKPOINT"));
      assert.ok(
        checkpoint.snapshot.includes("\x1b[?1049h"),
        "snapshot preserves alternate screen",
      );
      restored.send({
        type: "ack",
        sessionId: "terminal-1",
        cursor: checkpoint.cursor,
      });
      restored.send({
        type: "resize",
        sessionId: "terminal-1",
        cols: 90,
        rows: 30,
      });
      await until(() =>
        restored.messages.some(
          (m) => m.type === "attached" && m.session.cols === 90,
        ),
      );
      const resized = restored.messages
        .filter((m) => m.type === "attached")
        .at(-1);
      restored.send({
        type: "ack",
        sessionId: "terminal-1",
        cursor: resized.cursor,
      });
      restored.ws.close();
      await once(restored.ws, "close");
      const resumed = await connect();
      resumed.send({
        type: "attach",
        sessionId: "terminal-1",
        cursor: resized.cursor,
      });
      assert.equal(
        (await until(() => resumed.messages.find((m) => m.type === "attached")))
          .snapshot,
        undefined,
      );
      // A slow viewer stops receiving incremental frames; the host keeps running and checkpoints after overflow.
      const slow = await connect();
      slow.send({ type: "attach", sessionId: "terminal-2" });
      const slowStart = await until(() =>
        slow.messages.find((m) => m.type === "attached"),
      );
      slow.send({
        type: "ack",
        sessionId: "terminal-2",
        cursor: slowStart.cursor,
      });
      await api("/api/sessions/terminal-2/input", {
        commandId: "flood",
        text: "head -c 1200000 /dev/zero | tr '\\000' x; printf 'FLOOD-DONE'; touch flood-finished",
        sendReturn: true,
      });
      await until(async () =>
        fs.access(path.join(worktree, "flood-finished")).then(
          () => true,
          () => false,
        ),
      );
      await delay(150);
      const frames = slow.messages.filter((m) => m.type === "output");
      assert.ok(
        frames.reduce((n, f) => n + Buffer.byteLength(f.data), 0) < 200000,
        "unacknowledged output is bounded",
      );
      const last = frames.at(-1)!;
      slow.send({ type: "ack", sessionId: "terminal-2", cursor: last.cursor });
      const overflow = await until(() =>
        slow.messages.filter((m) => m.type === "attached").at(1),
      );
      assert.ok(overflow.snapshot.includes("FLOOD-DONE"));
      slow.ws.close();
      await once(slow.ws, "close");
      await api("/api/sessions/terminal-1/input", {
        commandId: "child",
        text: "sleep 60 & echo $! > child-pid",
        sendReturn: true,
      });
      const childPID = Number(
        await until(async () =>
          fs.readFile(path.join(worktree, "child-pid"), "utf8").catch(() => ""),
        ),
      );
      await api("/api/sessions/terminal-1", undefined, "DELETE");
      await until(() => {
        try {
          process.kill(childPID, 0);
          return false;
        } catch {
          return true;
        }
      });
      await until(
        async () =>
          (await api("/api/sessions")).body.sessions.find(
            (s: any) => s.id === "terminal-1",
          )?.status === "exited",
      );
      assert.equal(
        (
          await api("/api/sessions/terminal-1/input", {
            commandId: "late",
            text: "x",
            sendReturn: true,
          })
        ).status,
        409,
      );
      // Concurrent workspace mutations preserve both records and never share a temporary file.
      const second = { ...record, clusterId: "workspace-2" };
      await fs.writeFile(
        path.join(home, "workspaces", "index.json"),
        JSON.stringify([record, second]),
      );
      const archives = await Promise.all([
        api("/api/workspaces/workspace-1/archive", {}),
        api("/api/workspaces/workspace-2/archive", {}),
      ]);
      assert.deepEqual(
        archives.map((r) => r.status),
        [200, 200],
      );
      const index = JSON.parse(
        await fs.readFile(path.join(home, "workspaces", "index.json"), "utf8"),
      );
      assert.ok(index.every((r: any) => r.archivedAt));
      await api("/api/sessions/terminal-2/input", {
        commandId: "shutdown-child",
        text: "nohup sleep 60 >/dev/null 2>&1 & echo $! > shutdown-child",
        sendReturn: true,
      });
      shutdownChildPID = Number(
        await until(() =>
          fs
            .readFile(path.join(worktree, "shutdown-child"), "utf8")
            .catch(() => ""),
        ),
      );
      const exited = once(child, "exit");
      child.kill("SIGTERM");
      await exited;
      await until(() => {
        try {
          process.kill(shutdownChildPID!, 0);
          return false;
        } catch {
          return true;
        }
      }, 2000);
    } finally {
      for (const ws of sockets) ws.terminate();
      child.kill("SIGTERM");
      if (child.exitCode === null)
        await Promise.race([once(child, "exit"), delay(4000)]);
      if (shutdownChildPID) {
        try {
          process.kill(shutdownChildPID, "SIGKILL");
        } catch {}
      }
      if (child.exitCode === null) child.kill("SIGKILL");
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);

test(
  "Portless catalog and gateway reuse names, preserve HTTP/WebSocket routing, and release listeners",
  { timeout: 15000 },
  async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "slz-portless-"));
    const oldState = process.env.PORTLESS_STATE_DIR,
      oldHost = process.env.SLOPZOOKA_HOST;
    process.env.PORTLESS_STATE_DIR = dir;
    process.env.SLOPZOOKA_HOST = "127.0.0.1";
    const seen: string[] = [];
    const upstream = http.createServer((req, res) => {
      seen.push(req.headers.host!);
      if (req.url === "/action") {
        // Next.js Server Actions compare Origin with X-Forwarded-Host.
        const origin = new URL(req.headers.origin!);
        res.statusCode =
          origin.host === req.headers["x-forwarded-host"] ? 200 : 403;
        res.end(JSON.stringify(req.headers));
        return;
      }
      res.end(`app:${req.url}`);
    });
    const wss = new WebSocketServer({ server: upstream });
    wss.on("connection", (ws) => ws.on("message", (data) => ws.send(data)));
    const port = await listen(upstream);
    await fs.writeFile(path.join(dir, "proxy.port"), String(port));
    await fs.writeFile(path.join(dir, "proxy.tls"), "0");
    const route = {
      hostname: "feature.web.localhost",
      port: 4999,
      pid: process.pid,
    };
    const routes = (values: unknown) =>
      fs.writeFile(path.join(dir, "routes.json"), JSON.stringify(values));
    await routes([route]);
    const manager = new FrontendService(logger, {
      listeners: async () => [],
      home: dir,
    });
    try {
      assert.equal(
        (await manager.getCatalog()).frontends[0]?.id,
        route.hostname,
      );
      const [one, two] = await Promise.all([
        manager.openFrontend(route.hostname),
        manager.openFrontend(route.hostname),
      ]);
      assert.equal(one.exposedPort, two.exposedPort);
      const base = `http://127.0.0.1:${one.exposedPort}`;
      assert.equal((await fetch(base)).status, 401);
      const access = await fetch(
        `${base}/__slz_access?token=${one.accessToken}`,
        { redirect: "manual" },
      );
      const cookie = access.headers.get("set-cookie")!.split(";")[0]!;
      assert.equal(access.status, 303);
      assert.equal(
        await (
          await fetch(base + "/nested?x=1", { headers: { Cookie: cookie } })
        ).text(),
        "app:/nested?x=1",
      );
      assert.equal(seen.at(-1), `${route.hostname}:${port}`);
      const action = await fetch(base + "/action", {
        method: "POST",
        headers: {
          Cookie: cookie,
          Origin: base,
          "X-Forwarded-Host": "untrusted.invalid",
        },
      });
      assert.equal(action.status, 200);
      const forwarded = (await action.json()) as Record<string, string>;
      assert.equal(forwarded["x-forwarded-host"], forwarded.host);
      assert.equal(forwarded["x-forwarded-proto"], "http");
      const foreignAction = await fetch(base + "/action", {
        method: "POST",
        headers: { Cookie: cookie, Origin: "https://foreign.invalid" },
      });
      assert.equal(foreignAction.status, 403);
      const ws = new WebSocket(base.replace("http:", "ws:") + "/hmr", {
        headers: { Cookie: cookie },
      });
      await once(ws, "open");
      ws.send("hot-update");
      assert.equal((await once(ws, "message"))[0].toString(), "hot-update");
      ws.close();
      await once(ws, "close");
      await routes([route, { ...route, hostname: "api.localhost" }]);
      const apiRoute = await manager.openFrontend("api.localhost");
      const otherAccess = await fetch(
        `http://127.0.0.1:${apiRoute.exposedPort}/__slz_access?token=${apiRoute.accessToken}`,
        { redirect: "manual" },
      );
      assert.notEqual(
        otherAccess.headers.get("set-cookie")!.split("=")[0],
        cookie.split("=")[0],
      );
      await routes([{ ...route, port: 4111 }]);
      assert.equal(
        (await manager.openFrontend(route.hostname)).exposedPort,
        one.exposedPort,
      );
      await fs.writeFile(path.join(dir, "proxy.tls"), "partial");
      assert.ok((await manager.getCatalog()).warning);
      assert.equal(
        (await fetch(base, { headers: { Cookie: cookie } })).status,
        200,
      );
      await fs.writeFile(path.join(dir, "proxy.tls"), "0");
      // Validation must finish before a new proxy configuration can close live gateways.
      await fs.writeFile(path.join(dir, "proxy.port"), String(port + 1));
      await routes([{ ...route, port: "invalid" }]);
      assert.ok((await manager.getCatalog()).warning);
      assert.equal(
        (await fetch(base, { headers: { Cookie: cookie } })).status,
        200,
      );
      await fs.writeFile(path.join(dir, "proxy.port"), String(port));
      await fs.writeFile(path.join(dir, "routes.json"), "partial JSON");
      const stale = await manager.getCatalog();
      assert.equal(stale.frontends.length, 1);
      assert.ok(stale.warning);
      await routes([]);
      assert.equal((await manager.getCatalog()).frontends.length, 0);
      await assert.rejects(fetch(base));
      await fs.writeFile(path.join(dir, "proxy.lan"), "127.0.0.1");
      await routes([{ ...route, hostname: "web.local" }]);
      assert.equal(
        (await manager.openFrontend("web.local")).exposedPort,
        undefined,
      );
      await fs.unlink(path.join(dir, "proxy.lan"));
      await routes([route]);
      const opening = manager.openFrontend(route.hostname);
      const stopped = manager.stop();
      await assert.rejects(opening, /shutting down/);
      await stopped;
      await assert.rejects(
        manager.openFrontend(route.hostname),
        /shutting down/,
      );
    } finally {
      await manager.stop();
      wss.close();
      await new Promise<void>((r) => upstream.close(() => r()));
      if (oldState === undefined) delete process.env.PORTLESS_STATE_DIR;
      else process.env.PORTLESS_STATE_DIR = oldState;
      if (oldHost === undefined) delete process.env.SLOPZOOKA_HOST;
      else process.env.SLOPZOOKA_HOST = oldHost;
      await fs.rm(dir, { recursive: true, force: true });
    }
  },
);

test("branch resolution follows repository default and fails for an invalid explicit branch", async () => {
  const { resolveBaseRef } = await import("../src/workspace.js");
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "slz-branches-"));
  const git = (...args: string[]) =>
    execFileSync("git", ["-C", dir, ...args], { stdio: "pipe" });
  try {
    git("init", "-b", "main");
    git(
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--allow-empty",
      "-m",
      "initial",
    );
    git("branch", "master");
    git("update-ref", "refs/remotes/origin/main", "HEAD");
    git("update-ref", "refs/remotes/origin/master", "HEAD");
    const repo = {
      nameWithOwner: "test/repo",
      defaultBranch: "main",
    } as import("../src/github.js").RecentRepo;
    assert.equal(await resolveBaseRef(dir, repo), "origin/main");
    assert.equal(await resolveBaseRef(dir, repo, "master"), "origin/master");
    await assert.rejects(
      resolveBaseRef(dir, repo, "typo"),
      /Requested branch does not exist/,
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test(
  "HTTPS Portless gateway validates its CA and hostname and forwards application authorization",
  { timeout: 15000 },
  async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "slz-tls-"));
    const previous = process.env.PORTLESS_STATE_DIR,
      previousHost = process.env.SLOPZOOKA_HOST;
    process.env.PORTLESS_STATE_DIR = dir;
    process.env.SLOPZOOKA_HOST = "127.0.0.1";
    execFileSync(
      "openssl",
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        path.join(dir, "key.pem"),
        "-out",
        path.join(dir, "ca.pem"),
        "-days",
        "1",
        "-subj",
        "/CN=fixture.localhost",
        "-addext",
        "subjectAltName=DNS:fixture.localhost",
      ],
      { stdio: "ignore" },
    );
    const upstream = https.createServer(
      {
        key: await fs.readFile(path.join(dir, "key.pem")),
        cert: await fs.readFile(path.join(dir, "ca.pem")),
      },
      (req, res) => {
        assert.equal(
          req.headers.authorization,
          "Bearer application-credential",
        );
        assert.ok(!req.headers.cookie?.includes("slz_"));
        assert.equal(req.headers["x-forwarded-proto"], "https");
        assert.equal(req.headers["x-forwarded-host"], req.headers.host);
        assert.equal(new URL(req.headers.origin!).host, req.headers.host);
        res.end("trusted HTTPS");
      },
    );
    const port = await listen(upstream as any);
    await fs.writeFile(path.join(dir, "proxy.port"), String(port));
    await fs.writeFile(path.join(dir, "proxy.tls"), "1");
    await fs.writeFile(
      path.join(dir, "routes.json"),
      JSON.stringify([
        { hostname: "fixture.localhost", port: 4222, pid: process.pid },
      ]),
    );
    const manager = new FrontendService(logger, {
      listeners: async () => [],
      home: dir,
    });
    try {
      const opened = await manager.openFrontend("fixture.localhost");
      const base = `http://127.0.0.1:${opened.exposedPort}`;
      const access = await fetch(
        `${base}/__slz_access?token=${opened.accessToken}`,
        { redirect: "manual" },
      );
      const cookie = access.headers.get("set-cookie")!.split(";")[0]!;
      const response = await fetch(base, {
        headers: {
          Cookie: `${cookie}; slz_session=never-forward`,
          Authorization: "Bearer application-credential",
          Origin: base,
        },
      });
      assert.equal(response.status, 200);
      assert.equal(await response.text(), "trusted HTTPS");
      const saved = await manager.addURL(`https://fixture.localhost:${port}/`);
      assert.equal((await manager.getCatalog()).frontends.length, 1);
      const savedOpen = await manager.openFrontend(saved.id);
      const savedBase = `http://127.0.0.1:${savedOpen.exposedPort}`;
      const savedAccess = await fetch(
        `${savedBase}/__slz_access?token=${savedOpen.accessToken}`,
        { redirect: "manual" },
      );
      const savedResponse = await fetch(savedBase, {
        headers: {
          Cookie: savedAccess.headers.get("set-cookie")!.split(";")[0]!,
          Authorization: "Bearer application-credential",
          Origin: savedBase,
        },
      });
      assert.equal(
        await savedResponse.text(),
        "trusted HTTPS",
        "deduplicating a saved Portless URL preserves its certificate authority",
      );
    } finally {
      await manager.stop();
      await new Promise<void>((r) => upstream.close(() => r()));
      if (previous === undefined) delete process.env.PORTLESS_STATE_DIR;
      else process.env.PORTLESS_STATE_DIR = previous;
      if (previousHost === undefined) delete process.env.SLOPZOOKA_HOST;
      else process.env.SLOPZOOKA_HOST = previousHost;
      await fs.rm(dir, { recursive: true, force: true });
    }
  },
);

test(
  "concurrent real worktree launches serialize clone/fetch/index and migrate legacy records",
  { timeout: 20000 },
  async () => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-launches-"));
    const source = path.join(home, "remote");
    await fs.mkdir(source);
    const git = (...args: string[]) =>
      execFileSync("git", ["-C", source, ...args], { stdio: "pipe" });
    git("init", "-b", "main");
    git(
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--allow-empty",
      "-m",
      "initial",
    );
    git("branch", "master");
    const oldHome = process.env.SLOPZOOKA_HOME,
      oldCount = process.env.GIT_CONFIG_COUNT;
    const index = Number(oldCount ?? "0");
    const key = `GIT_CONFIG_KEY_${index}`,
      value = `GIT_CONFIG_VALUE_${index}`;
    const oldKey = process.env[key],
      oldValue = process.env[value];
    process.env.SLOPZOOKA_HOME = path.join(home, "host");
    process.env.GIT_CONFIG_COUNT = String(index + 1);
    process.env[key] = `url.file://${source}.insteadOf`;
    process.env[value] = "git@github.com:test/project.git";
    try {
      // Fresh module instance so environment-owned storage paths are isolated from other fixtures.
      const { WorkspaceService } = await import(
        new URL("../src/workspace.ts?launch-fixture", import.meta.url).href
      );
      const service = new WorkspaceService(logger);
      const repo = {
        name: "project",
        nameWithOwner: "test/project",
        sshUrl: "git@github.com:test/project.git",
        defaultBranch: "main",
        owner: { login: "test" },
      };
      const [one, two] = await Promise.all([
        service.launchWorkspace(
          { nameWithOwner: repo.nameWithOwner, profile: null },
          repo,
        ),
        service.launchWorkspace(
          { nameWithOwner: repo.nameWithOwner, profile: null },
          repo,
        ),
      ]);
      assert.notEqual(one.workspaceId, two.workspaceId);
      assert.notEqual(one.worktreePath, two.worktreePath);
      assert.equal(one.baseRef, "origin/main");
      assert.equal(two.baseRef, "origin/main");
      assert.equal((await service.listWorkspaces(100)).length, 2);
      await fs.access(one.worktreePath);
      await fs.access(two.worktreePath);
      await assert.rejects(
        service.launchWorkspace(
          {
            nameWithOwner: repo.nameWithOwner,
            profile: null,
            baseRef: "missing",
          },
          repo,
        ),
        /Requested branch does not exist/,
      );
      assert.equal((await service.listWorkspaces(100)).length, 2);
    } finally {
      for (const [name, original] of [
        ["SLOPZOOKA_HOME", oldHome],
        ["GIT_CONFIG_COUNT", oldCount],
        [key, oldKey],
        [value, oldValue],
      ] as const) {
        if (original === undefined) delete process.env[name];
        else process.env[name] = original;
      }
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);
