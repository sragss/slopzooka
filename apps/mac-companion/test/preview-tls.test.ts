import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { X509Certificate } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs/promises";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { WebSocket, WebSocketServer } from "ws";
import { FrontendService } from "../src/frontends.js";
import { PreviewTLS } from "../src/preview-tls.js";
import { tlsFetch } from "./https.js";

const exec = promisify(execFile);
const logger = {
  info() {},
  warn() {},
  error() {},
  logDir: "",
  logFilePath: "",
};

test(
  "HTTPS previews preserve secure login cookies, redirects, origins, and WSS with scoped certificate trust",
  { timeout: 60_000 },
  async (t) => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-preview-tls-"));
    t.after(() => fs.rm(home, { recursive: true, force: true }));
    const upstreamTLS = await new PreviewTLS(
      path.join(home, "upstream-tls"),
    ).certificate("fixture.localhost");
    let upstreamOrigin = "";
    const upstream = https.createServer(upstreamTLS, (req, res) => {
      assert.ok(!req.headers.cookie?.includes("slz_"));
      switch (req.url) {
        case "/login":
          assert.equal(req.method, "POST");
          res.writeHead(204, {
            "Set-Cookie":
              "__Host-app_session=logged-in; Secure; HttpOnly; SameSite=Lax; Path=/",
          });
          break;
        case "/session":
          res.statusCode = req.headers.cookie?.includes(
            "__Host-app_session=logged-in",
          )
            ? 200
            : 401;
          break;
        case "/redirect":
          res.writeHead(302, {
            Location: upstreamOrigin + "/welcome?next=1#done",
          });
          break;
        case "/relative-redirect":
          res.writeHead(302, {
            Location: "//" + new URL(upstreamOrigin).host + "/welcome",
          });
          break;
        case "/headers":
          res.setHeader("Access-Control-Allow-Origin", upstreamOrigin);
          res.end(JSON.stringify(req.headers));
          return;
        default:
          res.setHeader("Content-Type", "text/html");
          res.end("<!doctype html><title>Secure preview login fixture</title>");
          return;
      }
      res.end();
    });
    const sockets = new WebSocketServer({ server: upstream });
    sockets.on("connection", (ws, req) => {
      assert.equal(req.headers.origin, upstreamOrigin);
      ws.on("message", (data) => ws.send(data.toString()));
    });
    upstream.listen(0, "127.0.0.1");
    await once(upstream, "listening");
    const port = (upstream.address() as import("node:net").AddressInfo).port;
    upstreamOrigin = `https://fixture.localhost:${port}`;
    const stateDir = path.join(home, "portless");
    await fs.mkdir(stateDir);
    await fs.writeFile(
      path.join(stateDir, "ca.pem"),
      new X509Certificate(
        Buffer.from(upstreamTLS.certificateAuthority, "base64"),
      ).toString(),
    );
    await fs.writeFile(path.join(stateDir, "proxy.port"), String(port));
    await fs.writeFile(path.join(stateDir, "proxy.tls"), "1");
    await fs.writeFile(
      path.join(stateDir, "routes.json"),
      JSON.stringify([
        { hostname: "fixture.localhost", port: 4222, pid: process.pid },
      ]),
    );
    const manager = new FrontendService(logger, {
      home,
      stateDir,
      listeners: async () => [],
    });
    t.after(async () => {
      await manager.stop();
      for (const ws of sockets.clients) ws.terminate();
      sockets.close();
      await new Promise<void>((resolve) => upstream.close(() => resolve()));
    });
    const opened = await manager.openFrontend("fixture.localhost", "127.0.0.1");
    assert.equal(opened.gatewayScheme, "https");
    const ca = opened.certificateAuthority!;
    const base = `https://127.0.0.1:${opened.exposedPort}`;
    const accessURL = `${base}/__slz_access?token=${opened.accessToken}`;
    assert.equal((await tlsFetch(base, ca)).status, 401);
    await assert.rejects(
      tlsFetch(base, upstreamTLS.certificateAuthority),
      /certificate|issuer|self.signed/i,
    );
    await assert.rejects(
      tlsFetch(base, ca, { servername: "wrong.invalid" }),
      /not.*cert|altname|hostname/i,
    );
    const access = await tlsFetch(accessURL, ca);
    assert.equal(access.status, 303);
    assert.match(access.headers.get("set-cookie")!, /; Secure/);
    const cookie = access.headers.get("set-cookie")!.split(";")[0]!;
    const headers = {
      Cookie: cookie,
      Origin: base,
      Referer: base + "/page",
      Authorization: "Bearer application-only",
    };
    const response = await tlsFetch(base + "/headers", ca, { headers });
    assert.equal(response.headers.get("access-control-allow-origin"), base);
    const received = (await response.json()) as Record<string, string>;
    assert.equal(received.origin, upstreamOrigin);
    assert.equal(received.referer, upstreamOrigin + "/page");
    assert.equal(received["x-forwarded-proto"], "https");
    assert.equal(received.authorization, headers.Authorization);
    assert.equal(
      (await tlsFetch(base + "/redirect", ca, { headers })).headers.get(
        "location",
      ),
      base + "/welcome?next=1#done",
    );
    assert.equal(
      (
        await tlsFetch(base + "/relative-redirect", ca, { headers })
      ).headers.get("location"),
      base + "/welcome",
    );
    const login = await tlsFetch(base + "/login", ca, {
      headers,
      method: "POST",
    });
    assert.match(
      login.headers.get("set-cookie")!,
      /^__Host-app_session=.*; Secure; HttpOnly/,
    );
    const ws = new WebSocket(base.replace("https:", "wss:"), {
      headers,
      ca: new X509Certificate(Buffer.from(ca, "base64")).toString(),
    });
    await once(ws, "open");
    const echo = once(ws, "message");
    ws.send("secure HMR");
    assert.equal((await echo)[0].toString(), "secure HMR");
    ws.close();
    await once(ws, "close");
    const otherHost = await manager.openFrontend(
      "fixture.localhost",
      "localhost",
    );
    assert.notEqual(otherHost.exposedPort, opened.exposedPort);
    assert.equal(otherHost.certificateAuthority, ca);
    assert.equal(
      (await tlsFetch(base, ca, { headers })).status,
      200,
      "another client hostname does not replace an open gateway",
    );
    assert.equal(
      (await manager.openFrontend("fixture.localhost", "127.0.0.1"))
        .exposedPort,
      opened.exposedPort,
    );
    assert.equal(
      (await fs.stat(path.join(home, "preview-tls/authority.json"))).mode &
        0o777,
      0o600,
    );
    const nextTLS = await new PreviewTLS(
      path.join(home, "preview-tls"),
    ).certificate("127.0.0.1");
    assert.equal(
      nextTLS.certificateAuthority,
      ca,
      "CA survives companion restarts",
    );

    if (process.platform === "darwin") {
      await fs.writeFile(path.join(home, "ca.der"), Buffer.from(ca, "base64"));
      await fs.writeFile(
        path.join(home, "leaf.der"),
        new X509Certificate(nextTLS.cert).raw,
      );
      await fs.writeFile(
        path.join(home, "foreign.der"),
        Buffer.from(upstreamTLS.certificateAuthority, "base64"),
      );
      const vision = path.resolve(import.meta.dirname, "../../vision-client");
      const binary = path.join(home, "preview-checks");
      await exec(
        "xcrun",
        [
          "swiftc",
          "-swift-version",
          "5",
          "-parse-as-library",
          path.join(vision, "SlopZooka/SlopZooka/PreviewTrust.swift"),
          path.join(vision, "tests/PreviewTrustChecks.swift"),
          "-o",
          binary,
        ],
        { timeout: 30_000 },
      );
      const { stdout } = await exec(
        binary,
        [
          accessURL,
          path.join(home, "ca.der"),
          path.join(home, "leaf.der"),
          path.join(home, "foreign.der"),
        ],
        { timeout: 25_000 },
      );
      assert.match(stdout, /PASS: native certificate/);
      assert.match(stdout, /PASS: WebKit secure context/);
    }
  },
);
