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

test("a paired device dismisses its own code request and suppresses delayed requests", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-pairing-"));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  let now = 1000;
  const pairing = new Pairing(
    home,
    () => undefined,
    () => now,
  );
  const app = express();
  app.use(express.json());
  pairing.install(app);
  app.get("/health", (_req, res) => res.json({ ok: true }));
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const first = "11111111-1111-4111-8111-111111111111";
  const second = "22222222-2222-4222-8222-222222222222";
  const request = (
    client: string,
    path: string,
    token?: string,
    method = "GET",
  ) =>
    fetch(base + path, {
      method,
      headers: {
        "X-SlopZooka-Client-ID": client,
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
    });
  const paired = await fetch(base + "/api/pair", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-SlopZooka-Client-ID": first,
    },
    body: JSON.stringify({ code: pairing.code }),
  });
  const { token } = (await paired.json()) as { token: string };

  now += 61_000;
  await request(first, "/api/pair/display", undefined, "POST");
  const until = pairing.displayUntil;
  assert.ok(until > now);
  await request(first, "/health");
  assert.equal(
    pairing.displayUntil,
    until,
    "unauthenticated discovery cannot dismiss a code",
  );
  await request(second, "/health", token);
  assert.equal(
    pairing.displayUntil,
    until,
    "another paired device must not hide a new device's code",
  );
  await fetch(base + "/health", {
    headers: {
      Authorization: `Bearer ${token}`,
      "X-SlopZooka-Client-ID": first,
      Origin: "http://untrusted.example",
    },
  });
  assert.equal(
    pairing.displayUntil,
    until,
    "rejected origins cannot dismiss the code",
  );
  await request(first, "/health", token);
  assert.equal(
    pairing.displayUntil,
    0,
    "reconnecting with an existing credential dismisses the prompt",
  );

  now += 61_000;
  await request(first, "/health", token);
  await request(first, "/api/pair/display", undefined, "POST");
  assert.equal(
    pairing.displayUntil,
    0,
    "a delayed unpaired request cannot reopen the prompt",
  );
  await request(second, "/api/pair/display", undefined, "POST");
  assert.ok(
    pairing.displayUntil > now,
    "a different device can still request pairing",
  );
  await request(second, "/api/pair/display", token, "POST");
  assert.equal(
    pairing.displayUntil,
    0,
    "an authenticated display request clears its stale prompt",
  );

  now += 61_000;
  await request(first, "/api/pair/display", undefined, "POST");
  assert.ok(
    pairing.displayUntil > now,
    "expired connection activity does not suppress future pairing",
  );
});

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
  const display = () => fetch(`${base}/api/pair/display`, { method: "POST" });
  assert.equal(pairing.displayUntil, 0);
  assert.deepEqual(await (await display()).json(), { ok: true });
  const until = pairing.displayUntil;
  assert.equal(until, now + 45_000);
  now += 1_000;
  await display();
  assert.equal(
    pairing.displayUntil,
    until,
    "repeated requests do not keep the code onscreen",
  );
  assert.equal(
    (
      await fetch(`${base}/api/pair/display`, {
        method: "POST",
        headers: { Origin: "http://untrusted.example" },
      })
    ).status,
    403,
  );
  const response = await pair(original);
  assert.equal(response.status, 200);
  assert.equal(
    pairing.displayUntil,
    0,
    "successful pairing hides the Mac display",
  );
  const { token } = (await response.json()) as { token: string };
  for (let i = 0; i < 9; i++)
    assert.equal((await pair("invalid", `10.0.0.${i + 2}`)).status, 401);
  const limited = await pair(original, "10.0.1.1");
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("retry-after"), "60");
  now += 61_000;
  assert.equal((await pair(original)).status, 200);
  await fetch(`${base}/api/pair/display`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
  assert.equal(pairing.displayUntil, 0, "paired clients do not display a code");
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
