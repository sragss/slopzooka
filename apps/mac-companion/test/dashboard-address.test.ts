import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import https from "node:https";
import type net from "node:net";
import { once } from "node:events";
import { execFileSync, spawn } from "node:child_process";
import httpProxy from "http-proxy";
import { WebSocket } from "ws";
import { DashboardAddress } from "../src/dashboard-address.js";
import { Pairing } from "../src/auth.js";
const logger = {
  info() {},
  warn() {},
  error() {},
  logDir: "",
  logFilePath: "",
};
const hostname = "slopzooka.localhost";
async function listen(server: net.Server) {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return (server.address() as net.AddressInfo).port;
}
const close = (server: net.Server) =>
  new Promise<void>((resolve) => server.close(() => resolve()));
async function until<T>(check: () => Promise<T> | T): Promise<NonNullable<T>> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    await new Promise((r) => setTimeout(r, 30));
  }
  throw new Error("Timed out waiting for companion");
}

test("dashboard alias is optional, registered once, respects conflicts, verifies identity, and recovers", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-dashboard-"));
  let identity = "host-1";
  const proxy = http.createServer((_req, res) =>
    res.end(JSON.stringify({ hostId: identity })),
  );
  const port = await listen(proxy);
  let registrations = 0;
  const manager = new DashboardAddress(7777, "host-1", logger, {
    stateDir: home,
    register: async (dir, backendPort) => {
      registrations++;
      await fs.writeFile(
        path.join(dir, "routes.json"),
        JSON.stringify([{ hostname, port: backendPort, pid: 0 }]),
      );
    },
  });
  try {
    assert.equal(await manager.destination(), "http://localhost:7777/");
    assert.equal(
      registrations,
      0,
      "missing Portless does not block startup or try to install/start it",
    );
    await fs.writeFile(path.join(home, "proxy.port"), String(port));
    await Promise.all([manager.refresh(), manager.refresh()]);
    assert.equal(await manager.destination(), `http://${hostname}:${port}/`);
    assert.equal(registrations, 1);
    identity = "another-companion";
    assert.equal(
      await manager.destination(),
      manager.fallback,
      "never redirect to a different host",
    );
    identity = "host-1";
    assert.equal(await manager.destination(), `http://${hostname}:${port}/`);
    const conflict = JSON.stringify([{ hostname, port: 9999, pid: 0 }]);
    await fs.writeFile(path.join(home, "routes.json"), conflict);
    assert.equal(await manager.destination(), manager.fallback);
    assert.equal(
      await fs.readFile(path.join(home, "routes.json"), "utf8"),
      conflict,
    );
    assert.equal(
      registrations,
      1,
      "never call alias over an existing conflicting route",
    );
    await fs.writeFile(
      path.join(home, "routes.json"),
      JSON.stringify([{ hostname, port: 7777, pid: 0 }]),
    );
    await close(proxy);
    assert.equal(
      await manager.destination(),
      manager.fallback,
      "stopped proxy falls back",
    );
    await fs.writeFile(path.join(home, "proxy.port"), "443");
    await fs.writeFile(path.join(home, "proxy.tls"), "1");
    await manager.refresh();
    assert.equal(
      manager.proxyOrigin,
      "https://slopzooka.localhost",
      "standard HTTPS port is omitted",
    );
    await manager.stop();
    assert.equal(await manager.destination(), manager.fallback);
  } finally {
    await manager.stop();
    await close(proxy);
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("HTTPS origin trust is restricted to the registered dashboard, loopback, and proxy protocol", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-origin-"));
  const origin = "https://slopzooka.localhost:1355";
  const pairing = new Pairing(home, () => origin);
  const request = (
    originValue: string,
    host: string,
    address = "127.0.0.1",
    proto = "https",
  ) =>
    ({
      headers: { origin: originValue, host, "x-forwarded-proto": proto },
      socket: { remoteAddress: address },
    }) as any;
  try {
    assert.ok(pairing.sameOrigin(request(origin, "slopzooka.localhost:1355")));
    assert.ok(
      pairing.sameOrigin(
        request(origin, "slopzooka.localhost:1355", "::ffff:127.0.0.1"),
      ),
    );
    assert.ok(
      !pairing.sameOrigin(
        request(origin, "slopzooka.localhost:1355", "192.168.1.9"),
      ),
    );
    assert.ok(
      !pairing.sameOrigin(
        request(origin, "slopzooka.localhost:1355", "127.0.0.1", "http"),
      ),
    );
    assert.ok(
      !pairing.sameOrigin(
        request("http://slopzooka.localhost:1355", "slopzooka.localhost:1355"),
      ),
    );
    assert.ok(
      !pairing.sameOrigin(
        request("https://evil.localhost:1355", "slopzooka.localhost:1355"),
      ),
    );
    assert.ok(!pairing.sameOrigin(request(origin, "localhost:7777")));
    assert.ok(
      pairing.sameOrigin(
        request("http://localhost:7777", "localhost:7777", "192.168.1.9"),
      ),
    );
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test(
  "real companion pairs, serves terminals, and upgrades WebSockets through an HTTPS dashboard proxy",
  { timeout: 20000 },
  async () => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-dashboard-tls-"));
    execFileSync(
      "openssl",
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        path.join(home, "key.pem"),
        "-out",
        path.join(home, "ca.pem"),
        "-days",
        "1",
        "-subj",
        `/CN=${hostname}`,
        "-addext",
        `subjectAltName=DNS:${hostname}`,
      ],
      { stdio: "ignore" },
    );
    const ca = await fs.readFile(path.join(home, "ca.pem"));
    const placeholder = http.createServer();
    const backendPort = await listen(placeholder);
    await close(placeholder);
    const upstream = httpProxy.createProxyServer({
      target: `http://127.0.0.1:${backendPort}`,
      ws: true,
      headers: { "x-forwarded-proto": "https" },
    });
    upstream.on("error", (_error, _req, res) => {
      if ("writeHead" in res) {
        res.writeHead(502);
        res.end();
      } else res.destroy();
    });
    const proxy = https.createServer(
      { key: await fs.readFile(path.join(home, "key.pem")), cert: ca },
      (req, res) => upstream.web(req, res),
    );
    proxy.on("upgrade", (req, socket, head) => upstream.ws(req, socket, head));
    const sockets = new Set<net.Socket>();
    proxy.on("connection", (socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
    });
    const port = await listen(proxy);
    const origin = `https://${hostname}:${port}`;
    await fs.writeFile(path.join(home, "proxy.port"), String(port));
    await fs.writeFile(path.join(home, "proxy.tls"), "1");
    await fs.writeFile(
      path.join(home, "routes.json"),
      JSON.stringify([{ hostname, port: backendPort, pid: 0 }]),
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
          SLOPZOOKA_PORT: String(backendPort),
          SLOPZOOKA_HOST: "127.0.0.1",
          PORTLESS_STATE_DIR: home,
          SHELL: "/bin/sh",
        },
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let output = "";
    child.stdout.on("data", (chunk) => {
      output += chunk;
    });
    child.stderr.on("data", (chunk) => {
      output += chunk;
    });
    const request = (
      pathname: string,
      method = "GET",
      headers: Record<string, string> = {},
      body?: unknown,
    ) =>
      new Promise<{
        status: number;
        headers: http.IncomingHttpHeaders;
        body: string;
      }>((resolve, reject) => {
        const req = https.request(
          {
            hostname: "127.0.0.1",
            servername: hostname,
            port,
            path: pathname,
            method,
            ca,
            agent: false,
            headers: {
              Host: `${hostname}:${port}`,
              Origin: origin,
              ...headers,
              ...(body ? { "Content-Type": "application/json" } : {}),
            },
          },
          (res) => {
            let text = "";
            res.on("data", (chunk) => (text += chunk));
            res.on("error", reject);
            res.on("end", () =>
              resolve({
                status: res.statusCode!,
                headers: res.headers,
                body: text,
              }),
            );
          },
        );
        req.on("error", reject);
        req.end(body ? JSON.stringify(body) : undefined);
      });
    let ws: WebSocket | undefined;
    try {
      const code = await until(
        () => output.match(/pairing code: ([a-f0-9]+)/)?.[1],
      );
      const base = `http://127.0.0.1:${backendPort}`;
      await until(async () => {
        try {
          return (await fetch(base + "/health")).ok;
        } catch {
          return false;
        }
      });
      await until(
        async () =>
          (
            await fetch(base + "/dashboard", { redirect: "manual" })
          ).headers.get("location") ===
          origin + "/",
      );
      assert.equal(
        (
          await request(
            "/api/pair",
            "POST",
            { Origin: "https://foreign.invalid" },
            { code },
          )
        ).status,
        403,
      );
      await fs.writeFile(path.join(home, "ca.pem"), "");
      assert.equal(
        (await fetch(base + "/dashboard", { redirect: "manual" })).headers.get(
          "location",
        ),
        `http://localhost:${backendPort}/`,
        "untrusted proxy certificates fall back instead of bypassing TLS verification",
      );
      await fs.writeFile(path.join(home, "ca.pem"), ca);
      assert.equal(
        (await fetch(base + "/dashboard", { redirect: "manual" })).headers.get(
          "location",
        ),
        origin + "/",
      );
      const paired = await request("/api/pair", "POST", {}, { code });
      assert.equal(paired.status, 200, paired.body);
      const cookie = paired.headers["set-cookie"]![0]!;
      assert.match(cookie, /; Secure/);
      assert.match(cookie, /HttpOnly/);
      assert.match(cookie, /SameSite=Strict/);
      const headers = { Cookie: cookie.split(";")[0]! };
      assert.equal(
        (await request("/api/sessions", "GET", headers)).status,
        200,
      );
      assert.equal(
        (await request("/terminal?sessionId=test", "GET", headers)).status,
        200,
      );
      const catalog = JSON.parse(
        (await request("/api/frontends", "GET", headers)).body,
      );
      assert.ok(
        !catalog.frontends.some((entry: any) => entry.hostname === hostname),
        "dashboard is not listed as a project frontend",
      );
      assert.equal(
        (await request("/api/frontends", "POST", headers, { url: origin }))
          .status,
        400,
      );
      ws = new WebSocket(`wss://127.0.0.1:${port}/ws`, {
        ca,
        servername: hostname,
        headers: { ...headers, Host: `${hostname}:${port}`, Origin: origin },
      });
      const [, hello] = await Promise.all([
        once(ws, "open"),
        once(ws, "message"),
      ]);
      assert.equal(JSON.parse(hello[0].toString()).type, "hello");
      ws.close();
      await once(ws, "close");
      ws = undefined;
      for (const socket of sockets) socket.destroy();
      await close(proxy);
      const fallback = await fetch(base + "/dashboard", { redirect: "manual" });
      assert.equal(
        fallback.headers.get("location"),
        `http://localhost:${backendPort}/`,
      );
    } finally {
      ws?.terminate();
      child.kill("SIGTERM");
      if (child.exitCode === null) await once(child, "exit");
      for (const socket of sockets) socket.destroy();
      upstream.close();
      await close(proxy);
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);

test("shutdown cancels pending alias registration and leaves the shared proxy alone", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-dashboard-stop-"));
  await fs.writeFile(path.join(home, "proxy.port"), "1355");
  let began!: () => void;
  const started = new Promise<void>((resolve) => {
    began = resolve;
  });
  let cancelled = false;
  const manager = new DashboardAddress(7777, "host", logger, {
    stateDir: home,
    enabled: true,
    register: (_dir, _port, signal) =>
      new Promise((_resolve, reject) => {
        signal.addEventListener(
          "abort",
          () => {
            cancelled = true;
            reject(new Error("registration cancelled"));
          },
          { once: true },
        );
        began();
      }),
  });
  try {
    const pending = manager.refresh();
    await started;
    await manager.stop();
    await pending;
    assert.ok(cancelled);
    assert.equal(await manager.destination(), manager.fallback);
    assert.equal(
      await fs.readFile(path.join(home, "proxy.port"), "utf8"),
      "1355",
    );
  } finally {
    await manager.stop();
    await fs.rm(home, { recursive: true, force: true });
  }
});
