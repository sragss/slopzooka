import { createServer } from "node:https";
import { randomBytes, X509Certificate, timingSafeEqual } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { networkInterfaces } from "node:os";

export function packet(header, payload = Buffer.alloc(0)) {
  // Match the existing Swift MediaHeader, whose synthesized Decodable requires
  // non-optional fields even when its declarations have default values.
  const meta = Buffer.from(
    JSON.stringify({
      sequence: 0,
      timestamp: 0,
      width: 0,
      height: 0,
      keyframe: false,
      parameterSets: [],
      ...header,
    }),
  );
  if (meta.length > 65536 || payload.length > 8 * 1024 * 1024)
    throw new Error("Media packet too large");
  const prefix = Buffer.alloc(8);
  prefix.writeUInt32BE(meta.length, 0);
  prefix.writeUInt32BE(payload.length, 4);
  return Buffer.concat([prefix, meta, payload]);
}

// No model calls or durable window state. One cached latest frame per source;
// a slow socket can hold one packet, then frames are dropped until it drains.
export class FrameRelay {
  sources = new Map();
  add(id, label) {
    if (this.sources.size >= 8 || this.sources.has(id))
      throw new Error("Duplicate or excessive media source");
    this.sources.set(id, {
      id,
      label,
      generation: 1,
      sequence: 0,
      frames: 0,
      bytes: 0,
      ingressBytes: 0,
      drops: 0,
      peers: new Set(),
      latest: null,
      state: "waiting",
      intervals: [],
      lastAt: 0,
      streamId: null,
      revision: -1,
    });
  }
  push(event) {
    const source = this.sources.get(event.target);
    if (
      !source ||
      typeof event.data !== "string" ||
      event.data.length > 4 * 1024 * 1024
    )
      return false;
    if (source.streamId !== event.streamId) {
      // A new subscription is explicitly installed by bind(), never inferred from a late packet.
      return false;
    }
    if (event.revision < source.revision || event.sequence <= source.sequence)
      return false;
    if (event.revision !== source.revision) {
      source.generation++;
      source.latest = null;
    }
    source.revision = event.revision;
    source.sequence = event.sequence;
    const data = Buffer.from(event.data, "base64");
    const at = performance.now();
    if (source.lastAt) source.intervals.push(at - source.lastAt);
    if (source.intervals.length > 2048) source.intervals.shift();
    source.lastAt = at;
    source.frames++;
    source.bytes += data.length;
    source.ingressBytes += Buffer.byteLength(JSON.stringify(event)) + 4;
    source.state = "browser_screencast";
    source.latest = packet(
      {
        kind: "jpeg",
        generation: source.generation,
        sequence: event.sequence,
        timestamp: at / 1000,
        target: event.target,
        streamId: event.streamId,
        revision: event.revision,
      },
      data,
    );
    for (const peer of source.peers) this.send(source, peer, source.latest);
    return true;
  }
  bind(id, streamId) {
    const source = this.sources.get(id);
    if (!source) throw new Error("Unknown media source");
    source.streamId = streamId;
    source.sequence = 0;
    source.revision = -1;
    source.generation++;
    source.latest = null;
    source.state = "waiting";
  }
  pause(id, reason) {
    const source = this.sources.get(id);
    if (!source) return;
    source.streamId = null;
    source.latest = null;
    source.generation++;
    source.state = reason;
    const data = packet({
      kind: "paused",
      generation: source.generation,
      reason,
    });
    for (const peer of source.peers) {
      // End a blocked receiver so an old pending frame cannot hide revocation indefinitely.
      if (peer.writableLength) peer.destroy();
      else this.send(source, peer, data);
    }
  }
  send(source, peer, data) {
    if (peer.destroyed) {
      source.peers.delete(peer);
      return;
    }
    if (peer.writableLength) {
      source.drops++;
      return;
    }
    peer.write(data);
  }
  subscribe(id, peer) {
    const source = this.sources.get(id);
    if (!source) return false;
    source.peers.add(peer);
    peer.on("close", () => source.peers.delete(peer));
    if (source.latest) this.send(source, peer, source.latest);
    return true;
  }
  status() {
    return [...this.sources.values()].map((s) => ({
      id: s.id,
      label: s.label,
      state: s.state,
      generation: s.generation,
      streamId: s.streamId,
      frames: s.frames,
      bytes: s.bytes,
      ingressBytes: s.ingressBytes,
      drops: s.drops,
      subscribers: s.peers.size,
      sourceGapMs: s.lastAt ? performance.now() - s.lastAt : null,
      intervalsMs: s.intervals.slice(),
      latestBytes: s.latest?.length ?? 0,
    }));
  }
  heartbeat() {
    for (const s of this.sources.values())
      for (const peer of s.peers) {
        this.send(
          s,
          peer,
          packet({ kind: "status", generation: s.generation, reason: s.state }),
        );
      }
  }
  close() {
    for (const s of this.sources.values())
      for (const peer of s.peers) peer.destroy();
  }
}

export async function startMediaServer({ run, relay, lan = false, command }) {
  const keyPath = join(run, "media-key.pem"),
    certPath = join(run, "media-cert.pem");
  execFileSync(
    "/usr/bin/openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "7",
      "-subj",
      "/CN=SlopZooka Disposable Media",
      "-keyout",
      keyPath,
      "-out",
      certPath,
    ],
    { stdio: "ignore" },
  );
  const key = await readFile(keyPath),
    cert = await readFile(certPath);
  const { chmod } = await import("node:fs/promises");
  await chmod(keyPath, 0o600);
  const token = randomBytes(32).toString("hex");
  function authorized(req) {
    const actual = Buffer.from(req.headers.authorization ?? ""),
      expected = Buffer.from(`Bearer ${token}`);
    return (
      actual.length === expected.length && timingSafeEqual(actual, expected)
    );
  }
  const server = createServer({ key, cert }, async (req, res) => {
    res.setHeader("Cache-Control", "no-store");
    if (!authorized(req)) {
      res.writeHead(401).end();
      return;
    }
    try {
      const url = new URL(req.url, "https://probe.invalid");
      if (req.method === "GET" && url.pathname === "/status") {
        res.setHeader("Content-Type", "application/json");
        res.end(
          JSON.stringify({
            generation: 1,
            untilStopped: true,
            desktop: { state: "browser provider" },
            targets: relay.status().map(({ intervalsMs, ...s }) => s),
          }),
        );
      } else if (req.method === "GET" && url.pathname.startsWith("/stream/")) {
        const id = decodeURIComponent(url.pathname.slice(8));
        if (!relay.sources.has(id)) {
          res.writeHead(404).end();
          return;
        }
        res.writeHead(200, { "Content-Type": "application/octet-stream" });
        res.flushHeaders();
        relay.subscribe(id, res);
      } else if (
        req.method === "POST" &&
        url.pathname === "/command" &&
        command
      ) {
        let body = "";
        for await (const chunk of req) {
          body += chunk;
          if (body.length > 16384) throw new Error("Command too large");
        }
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(await command(JSON.parse(body))));
      } else res.writeHead(404).end();
    } catch (error) {
      if (!res.headersSent) res.writeHead(400);
      res.end(JSON.stringify({ error: error.message }));
    }
  });
  server.on("clientError", (_err, socket) => socket.destroy());
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, lan ? "0.0.0.0" : "127.0.0.1", resolve);
  });
  const candidates = Object.entries(networkInterfaces()).flatMap(
    ([name, addresses]) =>
      (addresses ?? [])
        .filter((a) => a.family === "IPv4" && !a.internal)
        .map((a) => ({ name, address: a.address })),
  );
  const host = lan
    ? (candidates.find((a) => a.name === "en0") ?? candidates[0])?.address
    : "127.0.0.1";
  if (!host) {
    server.close();
    throw new Error(
      "No LAN address; supply a reachable interface before headset use",
    );
  }
  const config = {
    host,
    port: server.address().port,
    token,
    fingerprint: new X509Certificate(cert).fingerprint256
      .replaceAll(":", "")
      .toLowerCase(),
  };
  await writeFile(join(run, "viewer-connection.json"), JSON.stringify(config), {
    mode: 0o600,
  });
  const timer = setInterval(() => relay.heartbeat(), 1000);
  timer.unref();
  return {
    config,
    async close() {
      clearInterval(timer);
      relay.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}
