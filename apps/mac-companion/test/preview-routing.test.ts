import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs/promises";
import net, { type AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { SessionServiceClient } from "../src/session-service-client.js";
import type { WindowLayout } from "../src/window-layout.js";

const root = path.resolve(import.meta.dirname, "..");
async function until<T>(read: () => Promise<T | undefined>) {
  const deadline = Date.now() + 25_000;
  while (Date.now() < deadline) {
    const result = await read();
    if (result !== undefined) return result;
    await delay(30);
  }
  throw new Error("Routing fixture timed out");
}
async function startCompanion(t: TestContext, codexHome: string, name: string) {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-preview-" + name));
  const reservation = net.createServer().listen(0, "127.0.0.1");
  await once(reservation, "listening");
  const port = (reservation.address() as AddressInfo).port;
  await new Promise<void>((resolve) => reservation.close(() => resolve()));
  const origin = "http://127.0.0.1:" + port;
  const child = spawn(
    process.execPath,
    [
      "--import",
      "tsx",
      "--import",
      "./test/fixtures/preview-catalog.mjs",
      "src/server.ts",
    ],
    {
      cwd: root,
      env: {
        ...process.env,
        SLOPZOOKA_HOME: home,
        SLOPZOOKA_PORT: String(port),
        SLOPZOOKA_HOST: "127.0.0.1",
        SLOPZOOKA_PORTLESS: "0",
        PORTLESS_STATE_DIR: path.join(home, "portless"),
        SLOPZOOKA_BONJOUR_NAME: "Slz routing fixture " + port,
        SLOPZOOKA_WINDOW_PREVIEWS: "1",
        CODEX_HOME: codexHome,
        SHELL: "/bin/sh",
        SLOPZOOKA_CODEX_COMMAND:
          JSON.stringify(process.execPath) +
          " " +
          JSON.stringify(path.join(root, "test/fixtures/codex.mjs")),
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const closed = once(child, "close");
  let code: string | undefined;
  child.stdout.on("data", (chunk: Buffer) => {
    code ??= /pairing code: (\d{6})/.exec(chunk.toString())?.[1];
  });
  child.stderr.resume();
  const service = await SessionServiceClient.forHome(home);
  let stopPolling = false;
  let polling = Promise.resolve();
  t.after(async () => {
    stopPolling = true;
    const pollingError = await polling.then(
      () => undefined,
      (e: unknown) => e,
    );
    child.kill();
    await closed;
    await service.stop().catch(() => {});
    await fs.rm(path.dirname(service.socketPath), {
      recursive: true,
      force: true,
    });
    await fs.rm(home, { recursive: true, force: true });
    if (pollingError) throw pollingError;
  });
  let status: number | undefined;
  const hostId = await until(async () => {
    if (child.exitCode !== null) throw new Error("Fixture companion exited");
    const res = await fetch(origin + "/health").catch(() => undefined);
    status = res?.status;
    if (code && res?.ok) return (await res.json()).hostId as string;
    return undefined;
  }).catch((cause: unknown) => {
    throw new Error(
      `Companion startup failed (rig=${name}, codeReceived=${Boolean(code)}, status=${status}, exit=${child.exitCode})`,
      { cause },
    );
  });
  const pair = await fetch(origin + "/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code }),
  });
  assert.equal(pair.status, 200);
  const { token } = (await pair.json()) as { token: string };
  const clientId = randomUUID();
  const api = async (url: string, body?: unknown) => {
    const res = await fetch(origin + url, {
      method: body === undefined ? "GET" : "POST",
      headers: {
        Authorization: "Bearer " + token,
        "X-SlopZooka-Client-ID": clientId,
        "Content-Type": "application/json",
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    assert.ok(res.ok, url + " HTTP " + res.status);
    return res.json();
  };
  let available = true;
  polling = (async () => {
    while (!stopPolling) {
      const layout = await api("/api/window-layout");
      if (available && layout.presentationProbe)
        await api("/api/window-layout/availability", {
          probe: layout.presentationProbe,
          available: true,
        });
      await delay(40);
    }
  })();
  // Keep polling errors observable during cleanup.
  void polling.catch(() => {});
  return {
    config: { origin, clientId, hostId, token },
    api,
    home,
    offline: () => {
      available = false;
    },
  };
}

test(
  "a saved thread resumed on the test companion keeps that pairing with the laptop default online",
  { timeout: 60000 },
  async (t) => {
    const codexHome = await fs.mkdtemp(
      path.join(os.tmpdir(), "slz-routing-codex-"),
    );
    await fs.mkdir(path.join(codexHome, "project"));
    t.after(() => fs.rm(codexHome, { recursive: true, force: true }));
    const prod = await startCompanion(t, codexHome, "regular");
    const rig = await startCompanion(t, codexHome, "test");
    assert.notEqual(prod.config.hostId, rig.config.hostId);
    const defaultFile = path.join(codexHome, "default.json");
    await fs.writeFile(defaultFile, JSON.stringify(prod.config), {
      mode: 0o600,
    });
    const defaultArgs = [
      "--import",
      "tsx",
      path.join(root, "src/preview-mcp.ts"),
      defaultFile,
    ];
    await fs.writeFile(
      path.join(codexHome, "config.toml"),
      `[mcp_servers.slopzooka-previews]\ncommand = ${JSON.stringify(process.execPath)}\nargs = ${JSON.stringify(defaultArgs)}\n`,
    );
    async function connect(command: string, args: string[]) {
      const client = new Client({ name: "routing-test", version: "1" });
      await client.connect(
        new StdioClientTransport({ command, args, cwd: root, stderr: "pipe" }),
      );
      t.after(() => client.close());
      return async (name: string, args: Record<string, unknown> = {}) => {
        const result = await client.callTool({ name, arguments: args });
        assert.ok(!result.isError, JSON.stringify(result.content));
        return JSON.parse((result.content as { text: string }[])[0]!.text);
      };
    }
    const laptop = await connect(process.execPath, defaultArgs);
    assert.equal((await laptop("preview_list")).host_id, prod.config.hostId);
    const baseline = (await prod.api("/api/window-layout")) as WindowLayout;
    const resumed = await rig.api(
      "/api/codex/threads/00000000-0000-4000-8000-000000000001/resume",
      { sessionId: "resumed-fixture" },
    );
    assert.equal(resumed.session.id, "resumed-fixture");
    // Consume the MCP command actually delivered to the fixture Codex PTY.
    const args = await until(async () => {
      const lines = await fs
        .readFile(path.join(codexHome, "calls.jsonl"), "utf8")
        .catch(() => "");
      return lines
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line))
        .find((call) => call.args?.includes("resume"))?.args as
        | string[]
        | undefined;
    });
    const setting = (key: string, fallback: unknown) => {
      const prefix = "mcp_servers.slopzooka-previews." + key + "=";
      const item = args.find((arg) => arg.startsWith(prefix));
      return item ? JSON.parse(item.slice(prefix.length)) : fallback;
    };
    const terminal = await connect(
      setting("command", process.execPath),
      setting("args", defaultArgs),
    );
    const catalog = await terminal("preview_list");
    assert.equal(catalog.host_id, rig.config.hostId);
    assert.equal(catalog.client_id, rig.config.clientId);
    const receipt = await terminal("preview_open", {
      source_id: catalog.sources[0].id,
      name: "Private test name",
    });
    assert.equal(receipt.confirmation, "write_reply");
    const saved = await rig.api("/api/window-layout");
    assert.deepEqual(saved.windows[0].ownerSessionIds, ["resumed-fixture"]);
    assert.equal(saved.windows[0].name, "Private test name");
    rig.offline();
    assert.equal((await terminal("preview_list")).state, "not_available");
    assert.equal((await laptop("preview_list")).headset_available, true);
    assert.deepEqual(await prod.api("/api/window-layout"), baseline);
    assert.deepEqual(await rig.api("/api/window-layout"), saved);
    const raw = await until(async () => {
      const logs = await fs.readFile(
        path.join(rig.home, "logs/mac-companion/current.jsonl"),
        "utf8",
      );
      return logs.includes("not_available") &&
        logs.includes("preview.write.confirmed")
        ? logs
        : undefined;
    });
    const events = raw
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    assert.ok(
      events.some(
        (e) =>
          e.event === "preview.list.completed" &&
          e.fields.state === "not_available" &&
          e.fields.clientId === rig.config.clientId,
      ),
    );
    const event = events.find((e) => e.event === "preview.write.confirmed");
    assert.equal(event.fields.hostId, rig.config.hostId);
    assert.equal(event.fields.clientId, rig.config.clientId);
    assert.equal(event.fields.sessionId, "resumed-fixture");
    assert.ok(
      events.some(
        (e) =>
          e.event === "http.completed" &&
          e.fields.method === "PUT" &&
          e.fields.actionId === event.fields.actionId,
      ),
    );
    assert.doesNotMatch(raw, /Private test name|Private fixture title/);
    assert.ok(!raw.includes(rig.config.token));
  },
);
