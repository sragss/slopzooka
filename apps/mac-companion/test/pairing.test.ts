import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { once } from "node:events";
import express from "express";
import { Pairing } from "../src/auth.js";

test("six-digit codes expire; rate limiting is host-wide and existing credentials survive rotation", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-pairing-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  let now = 1000;
  const pairing = new Pairing(
    home,
    () => undefined,
    () => now,
  );
  const original = pairing.code;
  assert.match(original, /^[0-9]{6}$/);
  const app = express();
  app.set("trust proxy", true);
  app.use(express.json());
  pairing.install(app);
  app.get("/private", (_req, res) => res.json({ ok: true }));
  const server = http.createServer(app);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const pair = (code: string, ip = "10.0.0.1") =>
    fetch(`${base}/api/pair`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Forwarded-For": ip },
      body: JSON.stringify({ code }),
    });
  const response = await pair(original);
  assert.equal(response.status, 200);
  const { token } = (await response.json()) as { token: string };
  for (let i = 0; i < 9; i++)
    assert.equal((await pair("invalid", `10.0.0.${i + 2}`)).status, 401);
  const limited = await pair(original, "10.0.1.1");
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("retry-after"), "60");
  now += 61_000;
  assert.equal((await pair(original)).status, 200);
  now += 5 * 60_000;
  assert.notEqual(pairing.code, original);
  assert.match(pairing.code, /^[0-9]{6}$/);
  assert.equal((await pair(original)).status, 401);
  assert.equal((await pair(pairing.code)).status, 200);
  assert.equal(
    (
      await fetch(`${base}/private`, {
        headers: { Authorization: `Bearer ${token}` },
      })
    ).status,
    200,
  );
  const saved = await fs.readFile(path.join(home, "pairing.json"), "utf8");
  assert.ok(!saved.includes(token));
});
