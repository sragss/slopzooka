import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import test from "node:test";
import express from "express";
import { PreviewControl } from "../src/preview-control.js";
import type { WindowLayout } from "../src/window-layout.js";
import { createDiagnostics, logContext } from "../src/logger.js";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

test("a lost layout reply gets one identity-checked readback and no replay", async (t) => {
  const app = express();
  app.use(express.json());
  const hostId = randomUUID(),
    clientId = randomUUID(),
    ownerSessionId = "test-session";
  let layout: WindowLayout = { version: 1, revision: 0, windows: [] };
  let host = hostId;
  let afterWrite: (() => void) | undefined;
  let reads = 0,
    writes = 0,
    checks = 0;
  let failRead = false;
  const actions: string[] = [];
  app.use((req, _res, next) => {
    actions.push(req.header("X-SlopZooka-Action-ID")!);
    next();
  });
  app.get("/health", (req, res) => {
    checks++;
    assert.equal(req.header("Authorization"), undefined);
    res.json({ hostId: host });
  });
  app.use((req, _res, next) => {
    assert.equal(req.header("X-SlopZooka-Client-ID"), clientId);
    assert.equal(req.header("Authorization"), "Bearer PRIVATE_TOKEN");
    next();
  });
  app.get("/api/frontends", (_req, res) =>
    res.json({
      windows: {
        state: "ready",
        sources: [
          {
            id: "window:a",
            title: "PRIVATE_TITLE",
            application: "Fixture",
            contentWidth: 100,
            contentHeight: 100,
          },
        ],
      },
    }),
  );
  app.get("/api/window-layout/availability", (_req, res) =>
    res.json({ available: true }),
  );
  app.get("/api/window-layout", (_req, res) => {
    reads++;
    if (failRead) res.destroy();
    else res.json(layout);
  });
  app.put("/api/window-layout", (req, res) => {
    writes++;
    layout = { ...req.body, revision: layout.revision + 1 };
    afterWrite?.();
    res.destroy();
  });
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-readback-"));
  const diagnostics = createDiagnostics("mac-companion", { home });
  t.after(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await diagnostics.store.flush();
    await fs.rm(home, { recursive: true, force: true });
  });
  const control = new PreviewControl(
    {
      hostId,
      clientId,
      ownerSessionId,
      token: "PRIVATE_TOKEN",
      origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    },
    diagnostics.logger("preview-routing"),
  );
  await logContext.run({ actionId: "lost-ack" }, async () => {
    const opened = await control.open("window:a", "PRIVATE_NAME");
    assert.equal(opened.confirmation, "layout_readback");
    assert.equal(opened.visibility, "not_observed");
    afterWrite = () =>
      layout.windows.push({ kind: "terminal", id: "other", targetID: "other" });
    const renamed = await control.rename(opened.preview_id, "PRIVATE_RENAME");
    assert.equal(renamed.confirmation, "layout_readback");
    afterWrite = undefined;
    assert.equal((await control.close(opened.preview_id)).desired_open, false);
    assert.deepEqual([checks, reads, writes], [6, 6, 3]);
    afterWrite = () => {
      layout.windows[1]!.name = "concurrent rename";
    };
    await assert.rejects(
      control.open("window:a", "PRIVATE_NAME"),
      /confirm whether/,
    );
    afterWrite = () => {
      layout.windows[1]!.ownerSessionIds = ["other"];
    };
    await assert.rejects(control.open("window:a"), /confirm whether/);
    afterWrite = () => {
      failRead = true;
    };
    await assert.rejects(control.close(opened.preview_id), /confirm whether/);
    failRead = false;
    afterWrite = () => {
      host = randomUUID();
    };
    await assert.rejects(control.open("window:a"), /confirm whether/);
    assert.deepEqual(
      [checks, reads, writes],
      [14, 13, 7],
      "replaced host never gets authenticated readback",
    );
  });
  assert.deepEqual(new Set(actions), new Set(["lost-ack"]));
  await diagnostics.store.flush();
  const raw = await fs.readFile(diagnostics.store.file, "utf8");
  const events = raw
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.equal(
    events.filter(
      (e) =>
        e.event === "preview.write.confirmed" &&
        e.fields.confirmation === "layout_readback",
    ).length,
    3,
  );
  assert.equal(
    events.filter((e) => e.event === "preview.write.uncertain").length,
    4,
  );
  assert.ok(
    events.every(
      (e) => e.fields.clientId === clientId && e.fields.actionId === "lost-ack",
    ),
  );
  assert.doesNotMatch(raw, /PRIVATE_|concurrent rename/);
});
