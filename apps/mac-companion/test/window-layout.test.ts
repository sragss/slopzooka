import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import express from "express";
import { Pairing } from "../src/auth.js";
import {
  WindowLayoutStore,
  installWindowLayoutRoutes,
} from "../src/window-layout.js";

const client = "11111111-1111-1111-1111-111111111111";
const otherClient = "22222222-2222-2222-2222-222222222222";
// The Swift recovery checks decode and round-trip this same wire contract.
const contract = JSON.parse(
  await fs.readFile(
    new URL(
      "../../../packages/protocol/fixtures/window-layout.v1.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const [terminal, preview] = contract.windows;

test("layouts survive restart, isolate clients, serialize conflicting edits, and reject corrupt stores", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-layout-"));
  try {
    const store = new WindowLayoutStore(home);
    const first = await store.put(client, 0, [terminal, preview]);
    assert.equal(first.revision, 1);
    assert.deepEqual(await new WindowLayoutStore(home).get(client), first);
    assert.deepEqual((await store.get(otherClient)).windows, []);
    const competing = await Promise.allSettled([
      store.put(client, 1, [preview]),
      store.put(client, 1, [terminal]),
    ]);
    assert.equal(competing[0].status, "fulfilled");
    assert.equal(competing[1].status, "rejected");
    assert.deepEqual((await store.get(client)).windows, [preview]);
    // Retrying an acknowledged close does not change identity or revision.
    assert.equal((await store.put(client, 2, [preview])).revision, 2);
    await store.put(otherClient, 0, [terminal]);
    assert.deepEqual((await store.get(client)).windows, [preview]);
    assert.equal(
      (await fs.stat(path.join(home, "window-layouts.json"))).mode & 0o777,
      0o600,
    );
    for (const invalid of [
      [terminal, terminal],
      [{ ...terminal, kind: "unknown" }],
      [{ ...terminal, targetID: "" }],
      [{ ...preview, name: " " }],
      [{ ...preview, name: "x".repeat(121) }],
      [{ ...preview, name: "bad\nname" }],
      Array(129).fill(terminal),
    ]) {
      await assert.rejects(store.put(client, 2, invalid));
    }
    await fs.writeFile(path.join(home, "window-layouts.json"), "broken");
    await assert.rejects(store.put(client, 2, []));
    assert.equal(
      await fs.readFile(path.join(home, "window-layouts.json"), "utf8"),
      "broken",
    );
  } finally {
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("layout API requires pairing and a client ID, checks revisions, and persists only content references", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-layout-api-"));
  const app = express();
  const pairing = new Pairing(home);
  app.use(express.json());
  pairing.install(app);
  installWindowLayoutRoutes(app, new WindowLayoutStore(home));
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const base = `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`;
  try {
    assert.equal((await fetch(base + "/api/window-layout")).status, 401);
    const paired = (await fetch(base + "/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: pairing.code }),
    }).then((r) => r.json())) as { token: string };
    const headers = {
      Authorization: `Bearer ${paired.token}`,
      "Content-Type": "application/json",
      "X-SlopZooka-Client-ID": client,
    };
    assert.equal(
      (
        await fetch(base + "/api/window-layout", {
          headers: { Authorization: headers.Authorization },
        })
      ).status,
      400,
    );
    assert.equal(
      (
        await fetch(base + "/api/window-layout", {
          headers: { ...headers, Origin: "https://untrusted.invalid" },
        })
      ).status,
      403,
    );
    const put = (
      revision: number,
      windows: unknown[],
      version: unknown = contract.version,
    ) =>
      fetch(base + "/api/window-layout", {
        method: "PUT",
        headers,
        body: JSON.stringify({ version, revision, windows }),
      });
    for (const version of [null, "1", 0, 2]) {
      assert.equal((await put(0, contract.windows, version)).status, 400);
    }
    assert.equal((await put(contract.revision, contract.windows)).status, 200);
    const savedContract = await fetch(base + "/api/window-layout", {
      headers,
    }).then((r) => r.json());
    assert.deepEqual(savedContract, { ...contract, revision: 1 });
    assert.equal(
      (
        await put(1, [
          {
            ...terminal,
            url: "http://secret",
            accessToken: "secret",
            position: [1, 2, 3],
          },
        ])
      ).status,
      200,
    );
    assert.equal((await put(0, [])).status, 409);
    const snapshot = (await fetch(base + "/api/window-layout", {
      headers,
    }).then((r) => r.json())) as { windows: unknown[] };
    assert.deepEqual(snapshot.windows, [terminal]);
    assert.equal((await put(2, [])).status, 200);
    assert.deepEqual(
      (await new WindowLayoutStore(home).get(client)).windows,
      [],
    );
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await fs.rm(home, { recursive: true, force: true });
  }
});
