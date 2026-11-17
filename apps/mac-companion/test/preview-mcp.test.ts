import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import express from "express";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { Pairing } from "../src/auth.js";
import {
  WindowLayoutStore,
  installWindowLayoutRoutes,
} from "../src/window-layout.js";
import { PreviewControl, readPreviewConfig } from "../src/preview-control.js";

const clientId = "11111111-1111-4111-8111-111111111111";
const otherClient = "22222222-2222-4222-8222-222222222222";

test("MCP stdio controls real authenticated layouts, rebases conflicts and isolates windows and clients", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-preview-mcp-"));
  const app = express();
  const pairing = new Pairing(home);
  const store = new WindowLayoutStore(home);
  const terminal = {
    id: "terminal",
    kind: "terminal" as const,
    targetID: "terminal",
  };
  const source = (id: string) => ({
    id: `window:${id}`,
    application: "Fixture",
    title: id,
    contentWidth: 390,
    contentHeight: 844,
  });
  let state = "ready";
  let headset: "active" | "background" | "offline" = "active";
  let polling = false;
  let poll: NodeJS.Timeout | undefined;
  let beforePut: (() => Promise<void>) | undefined;
  const requests: string[] = [];
  app.use(express.json());
  app.use((req, _res, next) => {
    requests.push(`${req.method} ${req.path}`);
    next();
  });
  app.get("/health", (_req, res) => {
    res.json({ hostId: pairing.hostId });
  });
  pairing.install(app);
  app.get("/api/sessions", (_req, res) =>
    res.json({ sessions: [{ id: "coordinated-terminal" }] }),
  );
  app.get("/api/frontends", (_req, res) => {
    res.json({ windows: { state, sources: [source("a"), source("b")] } });
  });
  app.put("/api/window-layout", async (_req, _res, next) => {
    const hook = beforePut;
    beforePut = undefined;
    if (hook) await hook();
    next();
  });
  installWindowLayoutRoutes(app, store, 300);
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const origin = `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`;
  const clients: Client[] = [];
  try {
    const { token } = (await fetch(origin + "/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: pairing.code }),
    }).then((r) => r.json())) as { token: string };
    const config = { origin, hostId: pairing.hostId, clientId, token };
    // Emulate only the headset's existing layout polling and readiness reply;
    // all companion auth, probe matching and persistence are real.
    poll = setInterval(() => {
      if (polling || headset === "offline") return;
      polling = true;
      const headers = {
        Authorization: `Bearer ${token}`,
        "X-SlopZooka-Client-ID": clientId,
        "Content-Type": "application/json",
      };
      void (async () => {
        const layout = (await fetch(origin + "/api/window-layout", {
          headers,
        }).then((r) => r.json())) as { presentationProbe?: string };
        if (layout.presentationProbe && headset !== "offline")
          await fetch(origin + "/api/window-layout/availability", {
            method: "POST",
            headers,
            body: JSON.stringify({
              probe: layout.presentationProbe,
              available: headset === "active",
            }),
          });
      })()
        .catch(() => {})
        .finally(() => {
          polling = false;
        });
    }, 15);
    const file = path.join(home, "config.json");
    await fs.writeFile(file, JSON.stringify(config), { mode: 0o600 });
    const start = async () => {
      const client = new Client({ name: "preview-test", version: "1.0.0" });
      clients.push(client);
      await client.connect(
        new StdioClientTransport({
          command: process.env.SLOPZOOKA_MCP_TEST_APP
            ? path.join(
                process.env.SLOPZOOKA_MCP_TEST_APP,
                "Contents/Resources/runtime/node",
              )
            : process.execPath,
          args: process.env.SLOPZOOKA_MCP_TEST_APP
            ? [
                path.join(
                  process.env.SLOPZOOKA_MCP_TEST_APP,
                  "Contents/Resources/host/src/preview-mcp.mjs",
                ),
                file,
              ]
            : [
                "--import",
                "tsx",
                fileURLToPath(
                  new URL("../src/preview-mcp.ts", import.meta.url),
                ),
                file,
              ],
          cwd: fileURLToPath(new URL("..", import.meta.url)),
          stderr: "pipe",
        }),
      );
      return client;
    };
    const first = await start();
    const second = await start();
    assert.match(
      first.getInstructions() ?? "",
      /unless the user explicitly requests/,
    );
    assert.match(
      first.getInstructions() ?? "",
      /do not automatically poll, retry, or queue/,
    );
    assert.ok(
      !requests.includes("GET /health") &&
        !requests.includes("GET /api/frontends"),
      "Installing/initializing MCP must not check the headset or enumerate windows automatically",
    );
    assert.deepEqual(
      (await first.listTools()).tools.map((t) => t.name).sort(),
      ["preview_close", "preview_list", "preview_open", "preview_rename"],
    );
    const call = async (
      client: Client,
      name: string,
      args: Record<string, unknown> = {},
    ) => {
      const result = await client.callTool({ name, arguments: args });
      assert.ok(!JSON.stringify(result).includes(token));
      assert.ok(!result.isError, JSON.stringify(result));
      const content = result.content as { type: string; text: string }[];
      return JSON.parse(content[0].text);
    };
    await store.put(clientId, 0, [terminal]);
    await store.put(otherClient, 0, [terminal]);
    // Installed MCP remains usable while the headset comes and goes; no restart.
    headset = "offline";
    const beforeOffline = await store.get(clientId);
    const offline = await call(first, "preview_list");
    assert.equal(offline.headset_available, false);
    assert.match(offline.message, /not available right now/);
    const unavailableOpen = await first.callTool({
      name: "preview_open",
      arguments: { source_id: "window:a" },
    });
    assert.equal(unavailableOpen.isError, true);
    assert.match(
      JSON.stringify(unavailableOpen),
      /No preview change was saved/,
    );
    assert.deepEqual(await store.get(clientId), beforeOffline);
    headset = "background";
    assert.equal((await call(first, "preview_list")).headset_available, false);
    headset = "active";
    const catalog = await call(first, "preview_list");
    assert.equal(catalog.sources.length, 2);
    // An intervening user close and another agent open must survive the retry.
    beforePut = async () => {
      await new PreviewControl(config).open("window:b", "Second agent");
      const saved = await store.get(clientId);
      await store.put(
        clientId,
        saved.revision,
        saved.windows.filter((w) => w.id !== terminal.id),
      );
    };
    const opened = await call(first, "preview_open", {
      source_id: "window:a",
      name: "Login",
    });
    assert.equal(opened.status, "desired_state_acknowledged");
    assert.equal(opened.visibility, "not_observed");
    assert.equal((await store.get(clientId)).windows.length, 2);
    assert.ok(
      !(await store.get(clientId)).windows.some((w) => w.kind === "terminal"),
    );
    assert.deepEqual((await store.get(otherClient)).windows, [terminal]);
    const duplicate = await call(second, "preview_open", {
      source_id: "window:a",
    });
    assert.equal(duplicate.preview_id, opened.preview_id);
    await Promise.all([
      call(first, "preview_rename", {
        preview_id: opened.preview_id,
        name: "Admin login",
      }),
      call(second, "preview_close", {
        preview_id: `${pairing.hostId}:window:b`,
      }),
    ]);
    assert.deepEqual(
      (await store.get(clientId)).windows.map((w) => w.name),
      ["Admin login"],
    );
    await assert.rejects(
      new PreviewControl({ ...config, clientId: otherClient }).rename(
        opened.preview_id,
        "Wrong target",
      ),
      /not open/,
    );
    assert.equal((await store.get(clientId)).windows[0].name, "Admin login");
    headset = "offline";
    const connectedLayout = await store.get(clientId);
    for (const [name, args] of [
      [
        "preview_rename",
        { preview_id: opened.preview_id, name: "Do not queue" },
      ],
      ["preview_close", { preview_id: opened.preview_id }],
    ] as const)
      assert.equal(
        (await first.callTool({ name, arguments: args })).isError,
        true,
      );
    assert.deepEqual(
      await store.get(clientId),
      connectedLayout,
      "Offline operations cannot queue mutations",
    );
    headset = "active";
    const restarted = await start();
    assert.equal(
      (await call(restarted, "preview_list")).previews[0].name,
      "Admin login",
    );
    await call(restarted, "preview_close", { preview_id: opened.preview_id });
    await call(first, "preview_close", { preview_id: opened.preview_id });
    assert.deepEqual((await store.get(clientId)).windows, []);
    for (const unavailable of ["locked", "permissionRequired", "failed"]) {
      state = unavailable;
      assert.equal((await call(first, "preview_list")).state, unavailable);
      assert.equal(
        (
          await first.callTool({
            name: "preview_open",
            arguments: { source_id: "window:a" },
          })
        ).isError,
        true,
      );
    }
    state = "ready";
    assert.equal(
      (
        await first.callTool({
          name: "preview_open",
          arguments: { source_id: "window:stale" },
        })
      ).isError,
      true,
    );
    const presentation = new PreviewControl(config);
    await assert.rejects(
      presentation.showTerminal("unknown"),
      /Terminal is unavailable/,
    );
    await presentation.showTerminal("coordinated-terminal");
    await presentation.showTerminal("coordinated-terminal");
    assert.equal(
      (await store.get(clientId)).windows.filter(
        (w) => w.id === "coordinated-terminal",
      ).length,
      1,
    );
    headset = "offline";
    const beforeOfflineTerminal = await store.get(clientId);
    await assert.rejects(
      presentation.showTerminal("coordinated-terminal"),
      /not available right now/,
    );
    assert.deepEqual(await store.get(clientId), beforeOfflineTerminal);
    headset = "active";
    const beforeWrongHost = requests.length;
    await assert.rejects(
      new PreviewControl({ ...config, hostId: otherClient }).open("window:a"),
      /identity changed/,
    );
    assert.deepEqual(requests.slice(beforeWrongHost), ["GET /health"]);
    await assert.rejects(
      new PreviewControl({ ...config, token: "invalid" }).open("window:a"),
      /HTTP 401/,
    );
    await assert.rejects(
      new PreviewControl({ ...config, clientId: otherClient }).rename(
        opened.preview_id,
        "Wrong target",
      ),
      /not open/,
    );
    await assert.rejects(
      new PreviewControl({ ...config, clientId: otherClient }).close(
        terminal.id,
      ),
      /only closes native/,
    );
    const retryPreview = await call(first, "preview_open", {
      source_id: "window:a",
      name: "Keep original",
    });
    beforePut = async () => {
      const current = await store.get(clientId);
      await store.put(clientId, current.revision, [
        ...current.windows,
        terminal,
      ]);
      headset = "offline";
    };
    const lostReadiness = await first.callTool({
      name: "preview_rename",
      arguments: {
        preview_id: retryPreview.preview_id,
        name: "Do not save on retry",
      },
    });
    assert.equal(lostReadiness.isError, true);
    const afterConflict = await store.get(clientId);
    assert.equal(
      afterConflict.windows.find((w) => w.id === retryPreview.preview_id)?.name,
      "Keep original",
    );
    assert.ok(
      afterConflict.windows.some((w) => w.id === terminal.id),
      "Offline conflict retry preserves intervening user intent",
    );
    headset = "active";
    await fs.chmod(file, 0o644);
    await assert.rejects(readPreviewConfig(file), /owner-only/);
    assert.ok(
      requests.every(
        (r) =>
          !(r.startsWith("POST ") && r.includes("/api/sessions")) &&
          !r.includes("/api/workspaces") &&
          !r.includes("/window-previews/open"),
      ),
      "MCP never launches processes or creates its own capture viewer",
    );
  } finally {
    clearInterval(poll);
    await Promise.all(clients.map((client) => client.close()));
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await fs.rm(home, { recursive: true, force: true });
  }
});
