import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import type { Duplex } from "node:stream";
import { promisify } from "node:util";
import test from "node:test";
import express from "express";
import { WebSocket, WebSocketServer } from "ws";
import { Pairing } from "../src/auth.js";
import {
  createPeerIngress,
  connectionMethod,
} from "../src/companion-transport.js";
import { webPresentation } from "../src/presentation.js";
import { PreviewTLS } from "../src/preview-tls.js";
import { SessionManager } from "../src/sessions.js";

const exec = promisify(execFile);
const root = path.resolve(import.meta.dirname, "../../..");
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until<T>(read: () => T | undefined | false): Promise<T> {
  const end = Date.now() + 8000;
  while (Date.now() < end) {
    const result = read();
    if (result) return result;
    await sleep(10);
  }
  throw new Error("Transport fixture timed out");
}
async function listen(server: http.Server) {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return `http://127.0.0.1:${address.port}`;
}

test(
  "native routes carry authenticated assets, HTTP and PTYs; retirement preserves the process and TLS rejects an impostor",
  { timeout: 60000 },
  async (t) => {
    const home = await fs.mkdtemp(
      path.join(os.tmpdir(), "slz-transport-check-"),
    );
    t.after(() => fs.rm(home, { recursive: true, force: true }));
    const binary = path.join(home, "transport-fixture");
    await exec(
      "xcrun",
      [
        "swiftc",
        "-swift-version",
        "5",
        "-strict-concurrency=complete",
        "-warnings-as-errors",
        "-parse-as-library",
        "packages/transport/NativeStream.swift",
        "apps/vision-client/SlopZooka/SlopZooka/CompanionTransport.swift",
        "apps/vision-client/SlopZooka/SlopZooka/CompanionClient.swift",
        "apps/vision-client/SlopZooka/SlopZooka/CompanionModels.swift",
        "apps/vision-client/SlopZooka/SlopZooka/WindowPersistence.swift",
        "apps/shared/Diagnostics.swift",
        "apps/shared/NativeLogFile.swift",
        "apps/vision-client/tests/TransportFixture.swift",
        "-o",
        binary,
      ],
      { cwd: root },
    );
    const sessions = new SessionManager();
    t.after(() => sessions.stop());
    await fs.writeFile(
      path.join(home, "reader.py"),
      "import os, tty\ntty.setraw(0)\nprint('TRANSPORT_READY', flush=True)\nwhile True:\n data=os.read(0,1024)\n print('RECEIVED:'+data.hex(), flush=True)\n",
    );
    const session = sessions.create(
      "transport",
      home,
      "codex",
      "transport-session",
      {
        ...process.env,
        SHELL: "/bin/sh",
        SLOPZOOKA_CODEX_COMMAND: "/usr/bin/python3 -u ./reader.py",
      },
    );
    const sibling = sessions.create(
      "transport",
      home,
      "codex",
      "transport-sibling",
      {
        ...process.env,
        SHELL: "/bin/sh",
        SLOPZOOKA_CODEX_COMMAND: "/usr/bin/python3 -u ./reader.py",
      },
    );
    const webkitBinary = path.join(home, "webkit-fixture");
    await exec(
      "xcrun",
      [
        "swiftc",
        "-swift-version",
        "5",
        "-strict-concurrency=complete",
        "-warnings-as-errors",
        "-parse-as-library",
        "apps/vision-client/tests/TransportWebKitChecks.swift",
        "-o",
        webkitBinary,
      ],
      { cwd: root },
    );
    const pairing = new Pairing(home);
    const app = express();
    app.use(express.json());
    pairing.install(app);
    let requests = 0;
    let transportVersion: number | undefined;
    let failDiagnostics = true;
    const uploads: any[] = [];
    app.get("/health", (req, res) =>
      res.json({
        hostId: "fixture",
        paired: pairing.authorized(req),
        diagnosticsVersion: 1,
        protocolVersion: 1,
        controlOrigin: "http://fixture.local",
        logFilePath: "",
        ...(transportVersion
          ? { transport: { version: transportVersion, direct: false } }
          : {}),
      }),
    );
    app.post("/api/diagnostics/events", (req, res) => {
      assert.equal(req.header("X-SlopZooka-Host-ID"), "fixture");
      assert.ok(pairing.authorized(req));
      uploads.push(req.body);
      res.status(failDiagnostics ? 503 : 200).json({ ok: !failDiagnostics });
      failDiagnostics = false;
    });
    app.get("/api/sessions", (_req, res) => res.json({ sessions: [] }));
    app.get("/api/frontends", (_req, res) => res.json({ frontends: [] }));
    app.use((_req, _res, next) => {
      if (_req.path === "/api/check") requests++;
      next();
    });
    app.get("/api/check", (_req, res) => res.json({ ok: true }));
    const finalResponse =
      "response-body-".repeat(32768) + "final-response-bytes";
    // Span several transport buffers; successful delivery includes every byte and EOF.
    app.get("/api/close-delimited", (_req, res) => {
      res.shouldKeepAlive = false;
      res.useChunkedEncodingByDefault = false;
      res.write(finalResponse);
      res.end();
    });
    app.get("/terminal", (_req, res) =>
      // The checkout may itself live under a hidden worktree directory.
      res.sendFile(path.join(root, "apps/mac-companion/public/terminal.html"), {
        dotfiles: "allow",
      }),
    );
    app.use(express.static(path.join(root, "apps/mac-companion/public")));
    const wss = new WebSocketServer({ noServer: true });
    t.after(() => {
      for (const ws of wss.clients) ws.terminate();
      wss.close();
    });
    const peers = new Map<WebSocket, { socket: Duplex; sessionId?: string }>();
    const attachments: string[] = [];
    const server = http.createServer(app);
    server.on("upgrade", (req, socket, head) => {
      if (!pairing.authorized(req) || !pairing.sameOrigin(req)) {
        socket.destroy();
        return;
      }
      if (
        req.url === "/api/window-stream/fixture" &&
        req.headers.upgrade === "slz-window-v1"
      ) {
        assert.equal(head.length, 0);
        socket.on("error", () => {});
        socket.write(
          "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: slz-window-v1\r\n\r\n",
        );
        socket.pipe(socket);
        return;
      }
      wss.handleUpgrade(req, socket, head, (ws) => {
        const peer: { socket: Duplex; sessionId?: string } = { socket };
        peers.set(ws, peer);
        ws.send(
          JSON.stringify({
            type: "hello",
            version: 1,
            serviceInstanceId: "fixture",
          }),
        );
        ws.on("message", (data) => {
          const message = JSON.parse(data.toString());
          const id = message.sessionId ?? session.id;
          if (message.type === "attach") {
            peer.sessionId = id;
            attachments.push(id);
            sessions.attach(ws, id, message.cursor);
          }
          if (message.type === "input") sessions.input(ws, id, message.data);
          if (message.type === "ack")
            sessions.acknowledge(ws, id, message.cursor);
        });
        ws.on("close", () => {
          peers.delete(ws);
          sessions.detach(ws);
        });
      });
    });
    const base = await listen(server);
    t.after(() => {
      server.closeAllConnections();
      server.close();
    });
    const pair = await fetch(base + "/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: pairing.code }),
    });
    const { token } = (await pair.json()) as { token: string };
    const identity = await new PreviewTLS(path.join(home, "tls")).certificate(
      "slopzooka.local",
    );
    await fs.writeFile(path.join(home, "key.pem"), identity.key, {
      mode: 0o600,
    });
    await fs.writeFile(path.join(home, "cert.pem"), identity.cert);
    await fs.writeFile(
      path.join(home, "ca.der"),
      Buffer.from(identity.certificateAuthority, "base64"),
    );
    await exec(
      "/usr/bin/openssl",
      [
        "pkcs12",
        "-export",
        "-inkey",
        "key.pem",
        "-in",
        "cert.pem",
        "-out",
        "identity.p12",
        "-passout",
        "pass:slopzooka-local",
        "-keypbe",
        "PBE-SHA1-3DES",
        "-certpbe",
        "PBE-SHA1-3DES",
      ],
      { cwd: home },
    );
    const wrong = await new PreviewTLS(path.join(home, "wrong")).certificate(
      "slopzooka.local",
    );
    await fs.writeFile(
      path.join(home, "wrong.der"),
      Buffer.from(wrong.certificateAuthority, "base64"),
    );

    for (const version of [undefined, 1]) {
      transportVersion = version;
      failDiagnostics = true;
      uploads.length = 0;
      const { stdout } = await exec(binary, [base, token, "client"]);
      const accepted = JSON.parse(stdout.trim()).url;
      assert.ok(uploads.length >= 2, "Failed native upload must be retried");
      const ids = (body: any) =>
        body.events.map(
          (event: any) => `${event.instanceId}:${event.sequence}`,
        );
      assert.ok(
        ids(uploads[0]).every((id: string) => ids(uploads[1]).includes(id)),
        "Unacknowledged event identities survive retry",
      );
      const serialized = JSON.stringify(uploads);
      assert.ok(
        !serialized.includes(token),
        "Diagnostics never include credentials",
      );
      assert.ok(
        !serialized.includes('"route":"/api/diagnostics/events"'),
        "Log delivery must not trace itself",
      );
      assert.equal(
        accepted === base,
        version === undefined,
        "Legacy companions retain their Host header; current companions share the native route adapter",
      );
    }
    for (const mode of ["lan", "tls", "wrong"] as const) {
      const args = [
        base,
        token,
        ...(mode === "lan"
          ? []
          : [
              path.join(home, "identity.p12"),
              path.join(home, mode === "wrong" ? "wrong.der" : "ca.der"),
            ]),
      ];
      const fixture = spawn(binary, args, { stdio: ["pipe", "pipe", "pipe"] });
      let output = "",
        errors = "";
      fixture.stdout.on("data", (data) => {
        output += data;
      });
      fixture.stderr.on("data", (data) => {
        errors = (errors + data).slice(-2000);
      });
      const closed = once(fixture, "close");
      try {
        const url = await until(() => output.match(/"url":"([^"]+)"/)?.[1]);
        const headers = { Authorization: `Bearer ${token}` };
        if (mode === "wrong") {
          const before = requests;
          await assert.rejects(
            fetch(url + "/api/check", {
              headers,
              signal: AbortSignal.timeout(1500),
            }),
          );
          await until(() => output.includes('"event":"stream.failed"'));
          await assert.rejects(
            fetch(url + "/api/check", {
              headers,
              signal: AbortSignal.timeout(1500),
            }),
          );
          const samples = output
            .split("\n")
            .filter((line) => line.includes('"event":"stream.failed"'))
            .map((line) => JSON.parse(line));
          assert.equal(
            samples.length,
            1,
            "Repeated TLS failures are sampled once per stage and route",
          );
          assert.equal(samples[0].fields.stage, "outgoing");
          assert.ok(samples[0].fields.errorCode);
          assert.ok(!JSON.stringify(samples).includes(token));
          assert.equal(
            requests,
            before,
            "TLS rejection must happen before HTTP or credentials reach the backend",
          );
          continue;
        }
        assert.equal((await fetch(url + "/api/check")).status, 401);
        // The same native route carries binary upgrades alongside HTTP and PTYs.
        // This runs through both the LAN adapter and pinned TLS/Direct adapter.
        const media = await new Promise<Duplex>((resolve, reject) => {
          const req = http.request(url + "/api/window-stream/fixture", {
            headers: {
              ...headers,
              Connection: "Upgrade",
              Upgrade: "slz-window-v1",
            },
          });
          req.once("upgrade", (_response, socket, head) => {
            if (head.length) socket.unshift(head);
            resolve(socket);
          });
          req.once("response", () =>
            reject(new Error("Expected native video upgrade")),
          );
          req.once("error", reject);
          req.end();
        });
        t.after(() => media.destroy());
        const mediaBytes: Buffer[] = [];
        media.on("data", (chunk: Buffer) => mediaBytes.push(chunk));
        const binaryPayload = Buffer.from(
          Array.from({ length: 350000 }, (_, index) => index % 256),
        );
        media.write(binaryPayload);
        await until(
          () => Buffer.concat(mediaBytes).length === binaryPayload.length,
        );
        assert.deepEqual(Buffer.concat(mediaBytes), binaryPayload);

        assert.equal(
          (await fetch(url + "/api/check", { headers })).status,
          200,
        );
        const terminal = await fetch(
          url + "/terminal?sessionId=transport-session",
          { headers },
        );
        assert.equal(terminal.status, 200);
        assert.match(await terminal.text(), /terminal.js/);
        assert.equal((await fetch(url + "/terminal.js")).status, 200);
        // A close-delimited HTTP response must deliver all final bytes and EOF.
        const endpoint = new URL(url);
        const socket = net.createConnection({
          host: endpoint.hostname,
          port: Number(endpoint.port),
        });
        let received = "";
        socket.on("data", (data) => {
          received += data;
        });
        const ended = once(socket, "end", {
          signal: AbortSignal.timeout(3000),
        });
        try {
          await once(socket, "connect");
          socket.write(
            `GET /api/close-delimited HTTP/1.1\r\nHost: ${endpoint.host}\r\nAuthorization: Bearer ${token}\r\nConnection: close\r\n\r\n`,
          );
          await ended;
          assert.ok(
            received.endsWith(finalResponse),
            "EOF must follow every final response byte",
          );
        } finally {
          socket.destroy();
        }
        const browser = spawn(
          webkitBinary,
          [url, token, session.id, sibling.id],
          { stdio: ["pipe", "pipe", "pipe"] },
        );
        let browserOutput = "",
          browserErrors = "";
        browser.stdout.on("data", (data) => {
          browserOutput += data;
        });
        browser.stderr.on("data", (data) => {
          browserErrors = (browserErrors + data).slice(-2000);
        });
        const browserClosed = once(browser, "close");
        try {
          const reported = (key: string, value: unknown) =>
            browserOutput.split("\n").some((line) => {
              try {
                return JSON.parse(line)[key] === value;
              } catch {
                return false;
              }
            });
          await until(() => reported("ready", true));
          browser.stdin.write("before\n");
          await until(() => reported("phase", "before"));
          const before = attachments.length;
          const retiring = [...peers.values()];
          assert.equal(
            retiring.length,
            2,
            "Two independent WebKit terminal sockets must be attached",
          );
          // Remote FIN without a WebSocket Close frame: leave the native route,
          // WebViews, and PTYs alive. Reconnection belongs to TerminalConnection.
          for (const peer of retiring) peer.socket.end();
          await until(() =>
            [session.id, sibling.id].every((id) =>
              attachments.slice(before).includes(id),
            ),
          );
          browser.stdin.write("after\n");
          await until(() => reported("phase", "after"));
          assert.deepEqual(
            attachments.slice(before).sort(),
            [session.id, sibling.id].sort(),
            "Each existing terminal must reattach exactly once without replacing its document or process",
          );
          console.log(
            `PASS: ${mode} two real WebKit terminals reconnect after remote EOF and render/acknowledge independent PTY input`,
          );
        } catch (error) {
          throw new Error(
            `${String(error)}\n${browserErrors}\n${browserOutput}`,
          );
        } finally {
          browser.stdin.end();
          // Cleanup is bounded even if a WebView has stalled in its own check.
          const cleanup = setTimeout(() => browser.kill(), 10000);
          await browserClosed;
          clearTimeout(cleanup);
        }
        await until(() => peers.size === 0);
        const attach = async (endpoint: string) => {
          const ws = new WebSocket(endpoint.replace("http:", "ws:") + "/ws", {
            headers: { ...headers, Origin: endpoint },
          });
          const messages: any[] = [];
          ws.on("message", (data) => {
            const message = JSON.parse(data.toString());
            messages.push(message);
          });
          await once(ws, "open");
          ws.send(JSON.stringify({ type: "attach" }));
          await until(() =>
            messages.find((message) => message.type === "attached"),
          );
          return {
            ws,
            text: () =>
              messages
                .map((message) => message.data ?? message.snapshot ?? "")
                .join(""),
          };
        };
        const first = await attach(url);
        const input = "Aé😀\u001b[D";
        first.ws.send(JSON.stringify({ type: "input", data: input }));
        await until(() =>
          first
            .text()
            .includes("RECEIVED:" + Buffer.from(input).toString("hex")),
        );
        const disconnected = once(first.ws, "close");
        const mediaClosed = once(media, "close");
        fixture.stdin.write("stop\n");
        await Promise.all([disconnected, mediaClosed]);
        assert.equal(sessions.summaries().length, 2);
        assert.equal(sessions.summaries()[0].status, "running");
        await assert.rejects(fetch(url + "/api/check", { headers }));
        output = "";
        fixture.stdin.write("restart\n");
        const next = await until(() => output.match(/"url":"([^"]+)"/)?.[1]);
        const second = await attach(next);
        second.ws.send(JSON.stringify({ type: "input", data: "reconnected" }));
        await until(() =>
          second
            .text()
            .includes("RECEIVED:" + Buffer.from("reconnected").toString("hex")),
        );
        const secondClosed = once(second.ws, "close");
        second.ws.close();
        await secondClosed;
        await until(() => peers.size === 0);
        assert.equal(
          sessions.summaries().length,
          2,
          "Route replacement never creates a terminal process",
        );
      } catch (error) {
        throw new Error(`${mode}: ${String(error)}\n${errors}\n${output}`);
      } finally {
        fixture.stdin.end();
        await closed;
      }
    }
  },
);

test("presentation support follows the accepting route, not a spoofed header or frontend URL type", async (t) => {
  const presentations = JSON.parse(
    await fs.readFile(
      path.join(root, "packages/protocol/fixtures/presentation.v1.json"),
      "utf8",
    ),
  );
  const frontend = {
    id: "web",
    hostname: "example.com",
    title: "Web",
    port: 443,
    url: "https://example.com",
    source: "manual" as const,
    status: "ready" as const,
    transport: "direct" as const,
  };
  const app = express();
  app.get("/", (req, res) =>
    res.json({
      method: connectionMethod(req),
      ...webPresentation(req, frontend),
    }),
  );
  const upgrades = new WebSocketServer({ noServer: true });
  t.after(() => upgrades.close());
  const upgrade = (
    req: http.IncomingMessage,
    socket: import("node:stream").Duplex,
    head: Buffer,
  ) => {
    upgrades.handleUpgrade(req, socket, head, (ws) => {
      ws.send(connectionMethod(req));
      ws.close();
    });
  };
  const lan = http.createServer(app);
  lan.on("upgrade", upgrade);
  for (const [server, method] of [
    [lan, "localNetwork"],
    [createPeerIngress(app, upgrade), "direct"],
  ] as const) {
    const base = await listen(server);
    t.after(() => {
      server.closeAllConnections();
      server.close();
    });
    const result = (await (
      await fetch(base, {
        headers: {
          "X-SlopZooka-Transport":
            method === "direct" ? "localNetwork" : "direct",
        },
      })
    ).json()) as any;
    assert.equal(result.method, method);
    const ws = new WebSocket(base, {
      headers: {
        "X-SlopZooka-Transport":
          method === "direct" ? "localNetwork" : "direct",
      },
    });
    const [acceptedMethod] = await once(ws, "message");
    assert.equal(
      acceptedMethod.toString(),
      method,
      "Upgrade attribution follows the accepting listener too",
    );
    await once(ws, "close");
    const { method: _acceptedMethod, ...presentation } = result;
    assert.deepEqual(presentation, presentations[method]);
    assert.equal(result.available, method === "localNetwork");
    if (method === "direct") {
      assert.equal(result.reasonCode, "presentation_unsupported_on_route");
      assert.deepEqual(result.alternatives, []);
    }
  }
});
