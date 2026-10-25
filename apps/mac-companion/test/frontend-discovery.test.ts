import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import net from "node:net";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { WebSocket, WebSocketServer } from "ws";
import { FrontendService } from "../src/frontends.js";
import {
  localListeners,
  parseListeners,
  type LocalListener,
} from "../src/frontend-discovery.js";
const logger = {
  info() {},
  warn() {},
  error() {},
  logDir: "",
  logFilePath: "",
};
async function listen(server: net.Server) {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return (server.address() as net.AddressInfo).port;
}
const close = (server: net.Server) =>
  new Promise<void>((resolve) => server.close(() => resolve()));

test("lsof parsing handles IPv4, IPv6-only wildcard, and duplicate descriptors", () => {
  assert.deepEqual(
    parseListeners(
      "p42\ncnode\nf1\ntIPv4\nn*:3000\nf2\ntIPv4\nn127.0.0.1:3000\np43\ncPython\nf3\ntIPv6\nn*:8000\n",
    ),
    [
      { pid: 42, command: "node", host: "127.0.0.1", port: 3000 },
      { pid: 43, command: "Python", host: "::1", port: 8000 },
    ],
  );
});

test(
  "unregistered local servers stream, upgrade, stop and recover without Portless; saved URLs persist",
  { timeout: 15000 },
  async () => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-frontends-"));
    const stateDir = path.join(home, "portless");
    let listeners: LocalListener[] = [];
    let finishStream: (() => void) | undefined;
    let responding = true;
    const server = http.createServer((req, res) => {
      if (req.method === "HEAD") {
        if (!responding) {
          req.socket.destroy();
          return;
        }
        res.end();
        return;
      }
      if (req.url === "/stream") {
        res.setHeader("Content-Type", "text/event-stream");
        res.write("data: first\n\n");
        finishStream = () => res.end("data: last\n\n");
      } else res.end(req.url);
    });
    const wss = new WebSocketServer({ server });
    wss.on("connection", (ws) => ws.on("message", (data) => ws.send(data)));
    const port = await listen(server);
    const binary = net.createServer((socket) => {
      socket.resume();
      socket.end("not HTTP\n");
    });
    const binaryPort = await listen(binary);
    listeners = [
      { pid: process.pid + 1, command: "Fixture", host: "127.0.0.1", port },
      {
        pid: process.pid + 1,
        command: "Database",
        host: "127.0.0.1",
        port: binaryPort,
      },
      {
        pid: process.pid,
        command: "SlopZooka",
        host: "127.0.0.1",
        port: 12345,
      },
    ];
    const manager = new FrontendService(logger, {
      home,
      stateDir,
      listeners: async () => listeners,
    });
    let replacement: FrontendService | undefined;
    try {
      const catalog = await manager.getCatalog();
      assert.equal(catalog.warning, null);
      assert.equal(catalog.frontends.length, 1);
      const frontend = catalog.frontends[0]!;
      assert.equal(frontend.status, "ready");
      assert.equal(frontend.source, "local");
      responding = false;
      assert.equal(
        (await manager.getCatalog()).frontends[0]!.status,
        "starting",
      );
      responding = true;
      const opened = await manager.openFrontend(frontend.id);
      const base = `http://127.0.0.1:${opened.exposedPort}`;
      const access = await fetch(
        `${base}/__slz_access?token=${opened.accessToken}`,
        { redirect: "manual" },
      );
      const cookie = access.headers.get("set-cookie")!.split(";")[0]!;
      const stream = await fetch(`${base}/stream`, {
        headers: { Cookie: cookie },
      });
      const reader = stream.body!.getReader();
      // A buffered proxy would hang here: the upstream has not ended the response.
      assert.equal(
        new TextDecoder().decode((await reader.read()).value),
        "data: first\n\n",
      );
      finishStream!();
      assert.equal(
        new TextDecoder().decode((await reader.read()).value),
        "data: last\n\n",
      );
      await reader.cancel();
      const ws = new WebSocket(base.replace("http:", "ws:") + "/hmr", {
        headers: { Cookie: cookie, Origin: base },
      });
      await once(ws, "open");
      ws.send("update");
      assert.equal((await once(ws, "message"))[0].toString(), "update");
      ws.close();
      await once(ws, "close");

      // A malformed optional source never blocks ordinary local apps.
      await fs.mkdir(stateDir);
      await fs.writeFile(path.join(stateDir, "routes.json"), "partial");
      assert.match((await manager.getCatalog()).warning!, /Portless/);
      assert.equal(
        (await manager.openFrontend(frontend.id)).exposedPort,
        opened.exposedPort,
      );

      listeners = [];
      assert.equal(
        (await manager.getCatalog()).frontends[0]!.status,
        "stopped",
      );
      await assert.rejects(manager.openFrontend(frontend.id), /Start this app/);
      const unavailable = await fetch(base, { headers: { Cookie: cookie } });
      assert.equal(unavailable.status, 503);
      assert.match(await unavailable.text(), /Local listener stopped/);
      listeners = [
        { pid: process.pid + 1, command: "Fixture", host: "127.0.0.1", port },
      ];
      assert.equal((await manager.getCatalog()).frontends[0]!.status, "ready");
      assert.equal(
        (await manager.openFrontend(frontend.id)).exposedPort,
        opened.exposedPort,
        "short restarts keep the existing preview address",
      );

      const saved = await manager.addURL(
        `http://localhost:${port}/nested?hello=world#section`,
      );
      assert.equal(saved.transport, "gateway");
      assert.equal(
        (await manager.getCatalog()).frontends.filter(
          (entry) => entry.source === "local",
        ).length,
        0,
        "saved localhost aliases replace duplicate auto-discovered entries",
      );
      assert.equal((await manager.addURL(saved.url)).id, saved.id);
      const savedOpen = await manager.openFrontend(saved.id);
      const savedBase = `http://127.0.0.1:${savedOpen.exposedPort}`;
      const bootstrap = await fetch(
        `${savedBase}/__slz_access?token=${savedOpen.accessToken}`,
        { redirect: "manual" },
      );
      assert.equal(
        bootstrap.headers.get("location"),
        "/nested?hello=world#section",
      );
      const savedCookie = bootstrap.headers.get("set-cookie")!.split(";")[0]!;
      assert.equal(
        await (
          await fetch(`${savedBase}/nested?hello=world`, {
            headers: { Cookie: savedCookie },
          })
        ).text(),
        "/nested?hello=world",
      );
      const remote = await manager.addURL(
        "https://example.invalid/preview?branch=feature",
      );
      assert.equal(
        (await manager.openFrontend(remote.id)).exposedPort,
        undefined,
      );
      assert.equal(remote.transport, "direct");
      await assert.rejects(manager.addURL("file:///etc/passwd"), /http/);
      await assert.rejects(
        manager.addURL("http://user:password@localhost:1234"),
        /credentials/,
      );
      await assert.rejects(
        manager.addURL("http://localhost:7777/"),
        /SlopZooka/,
      );
      assert.equal(
        (await fs.stat(path.join(home, "frontends.json"))).mode & 0o777,
        0o600,
      );
      replacement = new FrontendService(logger, {
        home,
        stateDir,
        listeners: async () => [],
      });
      assert.ok(
        (await replacement.getCatalog()).frontends.some(
          (entry) => entry.id === saved.id,
        ),
      );
      await manager.removeURL(saved.id);
      assert.ok(
        !(await manager.getCatalog()).frontends.some(
          (entry) => entry.id === saved.id,
        ),
      );
      await assert.rejects(fetch(savedBase));

      // Portless is authoritative for named routes, suppressing its backend and proxy listeners.
      await fs.writeFile(path.join(stateDir, "proxy.port"), String(binaryPort));
      await fs.writeFile(
        path.join(stateDir, "routes.json"),
        JSON.stringify([
          { hostname: "named.localhost", port, pid: process.pid },
        ]),
      );
      const named = await manager.getCatalog();
      assert.equal(
        named.frontends.filter((entry) => entry.source === "local").length,
        0,
      );
      assert.ok(
        named.frontends.some((entry) => entry.id === "named.localhost"),
      );
    } finally {
      finishStream?.();
      await manager.stop();
      await replacement?.stop();
      wss.close();
      await close(server);
      await close(binary);
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);

test(
  "macOS discovery finds a real child listener on an arbitrary port",
  { skip: process.platform !== "darwin", timeout: 10000 },
  async () => {
    const child = spawn(
      process.execPath,
      [
        "-e",
        "const s = require('http').createServer((q,r)=>r.end('ok'));s.listen(0,'127.0.0.1',()=>console.log(s.address().port));",
      ],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-lsof-"));
    let manager: FrontendService | undefined;
    try {
      const [data] = await once(child.stdout, "data");
      const port = Number(data.toString().trim());
      const listeners = (await localListeners()).filter(
        (entry) => entry.pid === child.pid,
      );
      assert.ok(listeners.some((entry) => entry.port === port));
      manager = new FrontendService(logger, {
        home,
        stateDir: path.join(home, "absent"),
        listeners: async () => listeners,
      });
      const catalog = await manager.getCatalog();
      assert.equal(catalog.frontends[0]?.status, "ready");
      assert.equal(catalog.frontends[0]?.port, port);
    } finally {
      await manager?.stop();
      child.kill();
      await once(child, "exit");
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);

test("discovery groups browser apps, retains services, associates projects, and deduplicates named routes", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-catalog-"));
  const stateDir = path.join(home, "portless");
  const project = path.join(home, "project");
  const childDir = path.join(project, "src");
  await fs.mkdir(childDir, { recursive: true });
  await fs.writeFile(
    path.join(project, "package.json"),
    JSON.stringify({ name: "storefront" }),
  );
  let contentType = "text/html; charset=utf-8";
  const app = http.createServer((_req, res) => {
    res.setHeader("Content-Type", contentType);
    res.end();
  });
  const backend = http.createServer((_req, res) => {
    res.setHeader("Content-Type", "application/json");
    res.end("{}");
  });
  const appPort = await listen(app),
    apiPort = await listen(backend);
  const listeners: LocalListener[] = [
    {
      pid: process.pid + 1,
      command: "node",
      cwd: childDir,
      host: "127.0.0.1",
      port: appPort,
    },
    {
      pid: process.pid + 2,
      command: "node",
      cwd: project,
      host: "127.0.0.1",
      port: apiPort,
    },
  ];
  const manager = new FrontendService(logger, {
    home,
    stateDir,
    listeners: async () => [...listeners, listeners[0]!],
  });
  try {
    const catalog = await manager.getCatalog();
    assert.equal(catalog.frontends.length, 2);
    assert.deepEqual(
      catalog.frontends.map((f) => f.category),
      ["app", "service"],
    );
    assert.ok(catalog.frontends.every((f) => f.project === "storefront"));
    delete listeners[0]!.cwd;
    assert.ok(
      (await manager.getCatalog()).frontends.every(
        (f) => f.category === "service",
      ),
      "HTML without a detected project stays under Other services",
    );
    listeners[0]!.cwd = childDir;
    contentType = "application/json";
    assert.ok(
      (await manager.getCatalog()).frontends.every(
        (f) => f.category === "service",
      ),
      "classification follows current headers",
    );
    await fs.mkdir(stateDir);
    await fs.writeFile(path.join(stateDir, "proxy.port"), "1355");
    await fs.writeFile(
      path.join(stateDir, "routes.json"),
      JSON.stringify([
        { hostname: "store.localhost", port: appPort, pid: process.pid },
      ]),
    );
    const named = (await manager.getCatalog()).frontends;
    assert.equal(named.length, 2, "Portless replaces its backend listener");
    assert.equal(named[0]?.project, "storefront");
    assert.equal(
      named[0]?.category,
      "app",
      "explicit named apps remain primary even with API roots",
    );
    const saved = await manager.addURL("http://store.localhost:1355/");
    assert.equal(
      (await manager.getCatalog()).frontends.filter((f) => f.url === saved.url)
        .length,
      1,
    );
    await manager.removeURL(saved.id);
    assert.ok(
      (await manager.getCatalog()).frontends.some(
        (f) => f.id === "store.localhost",
      ),
    );
  } finally {
    await manager.stop();
    await close(app);
    await close(backend);
    await fs.rm(home, { recursive: true, force: true });
  }
});

test(
  "a real dev-server restart preserves preview URL and credentials, with diagnostic failure pages",
  { timeout: 10000 },
  async () => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-restart-"));
    let server = http.createServer((_req, res) => {
      res.setHeader("Content-Type", "text/html");
      res.end("before");
    });
    const port = await listen(server);
    let listening = true;
    const manager = new FrontendService(logger, {
      home,
      stateDir: path.join(home, "absent"),
      listeners: async () =>
        listening
          ? [
              {
                pid: process.pid + 1,
                command: "Fixture",
                host: "127.0.0.1",
                port,
              },
            ]
          : [],
    });
    try {
      const frontend = (await manager.getCatalog()).frontends[0]!;
      const opened = await manager.openFrontend(frontend.id);
      const base = `http://127.0.0.1:${opened.exposedPort}`;
      const auth = await fetch(
        `${base}/__slz_access?token=${opened.accessToken}`,
        { redirect: "manual" },
      );
      const headers = {
        Cookie: auth.headers.get("set-cookie")!.split(";")[0]!,
      };
      assert.equal(await (await fetch(base, { headers })).text(), "before");
      await close(server);
      // Before discovery notices, upstream connection errors still retain the real diagnostic.
      const failure = await fetch(base, { headers });
      assert.equal(failure.status, 502);
      assert.match(failure.headers.get("content-type")!, /text\/html/);
      const body = await failure.text();
      assert.match(body, /ECONNREFUSED/);
      assert.match(body, /<summary>Details<\/summary>/);
      listening = false;
      assert.equal(
        (await manager.getCatalog()).frontends[0]?.status,
        "stopped",
      );
      assert.equal((await fetch(base, { headers })).status, 503);
      server = http.createServer((_req, res) => {
        res.setHeader("Content-Type", "text/html");
        res.end("after");
      });
      server.listen(port, "127.0.0.1");
      await once(server, "listening");
      listening = true;
      await manager.getCatalog();
      const reopened = await manager.openFrontend(frontend.id);
      assert.equal(reopened.exposedPort, opened.exposedPort);
      assert.equal(reopened.accessToken, opened.accessToken);
      assert.equal(await (await fetch(base, { headers })).text(), "after");
    } finally {
      await manager.stop();
      await close(server);
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);

test(
  "shutdown cancels in-flight discovery and rejects queued opens without leaving gateways",
  { timeout: 5000 },
  async () => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-stop-"));
    let started!: () => void;
    const pending = new Promise<void>((resolve) => {
      started = resolve;
    });
    let aborted = false;
    const manager = new FrontendService(logger, {
      home,
      stateDir: home,
      listeners: (signal) =>
        new Promise((resolve) => {
          signal!.addEventListener(
            "abort",
            () => {
              aborted = true;
              resolve([]);
            },
            { once: true },
          );
          started();
        }),
    });
    try {
      const catalog = manager.getCatalog();
      await pending;
      const opening = manager.openFrontend("missing");
      const rejected = assert.rejects(opening, /shutting down/);
      await Promise.all([manager.stop(), manager.stop(), catalog, rejected]);
      assert.ok(aborted);
      await assert.rejects(
        manager.addURL("http://localhost:3000"),
        /shutting down/,
      );
    } finally {
      await manager.stop();
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);
