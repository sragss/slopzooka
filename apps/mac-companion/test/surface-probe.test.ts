import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import express from "express";
import {
  SurfaceProbeCommands,
  installSurfaceProbe,
} from "../src/surface-probe.js";
import { Pairing } from "../src/auth.js";
import { probeSurface } from "../../../packages/protocol/src/surface-probe.js";

const manifestPath = new URL(
  "../../../packages/protocol/fixtures/surface-probe.v1.json",
  import.meta.url,
);
test("probe delivery deduplicates intent, isolates receivers, fails replacements and expires uncertain commands", () => {
  let now = 1000;
  const q = new SurfaceProbeCommands(() => now);
  const command = {
    id: "one",
    action: "open" as const,
    surfaceID: "probe:fixture",
  };
  assert.throws(() => q.submit("client", command), /active paired/);
  q.poll("client", "receiver-1", true, [], []);
  q.submit("client", command);
  assert.equal(q.submit("client", command).id, "one");
  assert.throws(
    () => q.submit("client", { ...command, action: "close" }),
    /reused/,
  );
  assert.equal(q.poll("other", "receiver-2", true, [], []).commands.length, 0);
  assert.equal(q.poll("client", "receiver-1", true, [], []).commands.length, 1);
  q.poll("client", "receiver-1", true, [{ id: "one" }], []);
  assert.equal(q.poll("client", "receiver-1", true, [], []).commands.length, 0);
  q.submit("client", { ...command, id: "two" });
  q.poll("client", "new-receiver", true, [], []);
  assert.equal(q.commands.get("two")?.state, "failed");
  q.submit("client", { ...command, id: "three" });
  now += 31000;
  q.poll("client", "new-receiver", true, [], []);
  assert.equal(q.commands.get("three")?.state, "failed");
  q.poll("client", "new-receiver", false, [], []);
  assert.throws(
    () => q.submit("client", { ...command, id: "four" }),
    /active paired/,
  );
});
test("probe routes require pairing, resolve only local manifest surfaces and never store stream credentials in command state", async () => {
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  const surface = probeSurface(manifest.surfaces[0]);
  assert.throws(() =>
    probeSurface({ ...surface, stream: { ...surface.stream, port: 0 } }),
  );
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-probe-api-"));
  const app = express(),
    pairing = new Pairing(home);
  app.use(express.json());
  pairing.install(app);
  installSurfaceProbe(app, manifestPath.pathname);
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const base = `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`;
  try {
    assert.equal((await fetch(base + "/api/surface-probe")).status, 401);
    const paired = (await fetch(base + "/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: pairing.code }),
    }).then((r) => r.json())) as { token: string };
    const headers = {
      Authorization: `Bearer ${paired.token}`,
      "Content-Type": "application/json",
      "X-SlopZooka-Client-ID": "client",
    };
    const post = (p: string, b: unknown) =>
      fetch(base + p, { method: "POST", headers, body: JSON.stringify(b) });
    assert.equal(
      (
        await post("/api/surface-probe/poll", {
          receiverID: "receiver",
          available: true,
          results: [],
          presence: [],
        })
      ).status,
      200,
    );
    assert.equal(
      (
        await post("/api/surface-probe/commands", {
          id: "test",
          clientID: "client",
          action: "open",
          surfaceID: surface.id,
        })
      ).status,
      200,
    );
    assert.equal(
      (await post("/api/surface-probe/resolve", { id: "probe:missing" }))
        .status,
      404,
    );
    assert.deepEqual(
      await (
        await post("/api/surface-probe/resolve", { id: surface.id })
      ).json(),
      surface,
    );
    const status = await fetch(base + "/api/surface-probe", { headers }).then(
      (r) => r.text(),
    );
    assert(!status.includes(surface.stream.token));
    assert.equal(
      (await fs.readdir(home)).includes("window-layouts.json"),
      false,
      "Command transport never writes desired layouts",
    );
  } finally {
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
    await fs.rm(home, { recursive: true, force: true });
  }
});
