// Live-model tool-selection probe with disposable HTTP fixtures. No headset,
// native control, production companion, real PTY, or project mutations.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { createRequire } from "node:module";
const express = createRequire(
  new URL("../../apps/mac-companion/package.json", import.meta.url),
)("express");
import { Coordinator } from "../../apps/mac-companion/src/coordinator.js";
import { normalizedName } from "../../apps/mac-companion/src/names.js";
import {
  WindowLayoutStore,
  installWindowLayoutRoutes,
} from "../../apps/mac-companion/src/window-layout.js";

const home = await fs.mkdtemp("/tmp/slz-coordinator-context-");
const configFile =
  process.env.SLOPZOOKA_COORDINATOR_CONFIG ??
  path.join(os.homedir(), ".slopzooka/coordinator-development/config.json");
const clientId = randomUUID(),
  hostId = randomUUID(),
  sessionId = randomUUID();
const store = new WindowLayoutStore(home);
await store.put(clientId, 0, [
  { id: sessionId, kind: "terminal", targetID: sessionId },
  {
    id: "fixture-preview",
    kind: "preview",
    targetID: "window:fixture",
    name: "Fixture preview",
  },
]);
let title = "Shell";
const routes: string[] = [];
const app = express();
app.use(express.json());
app.use((req, _res, next) => {
  routes.push(req.method + " " + req.path);
  next();
});
app.get("/health", (_req, res) => res.json({ hostId }));
app.get("/api/repos/recent", (_req, res) => res.json({ repos: [] }));
app.get("/api/workspaces", (_req, res) =>
  res.json({
    workspaces: [{ workspaceId: "fixture", name: "Fixture workspace" }],
  }),
);
app.get("/api/sessions", (_req, res) =>
  res.json({
    sessions: [
      { id: sessionId, workspaceId: "fixture", title: "Shell", name: title },
    ],
  }),
);
app.patch("/api/sessions/:id", (req, res) => {
  assert.equal(req.params.id, sessionId);
  title = normalizedName(req.body.name);
  res.json({ session: { id: sessionId, name: title } });
});
app.get("/api/frontends", (_req, res) =>
  res.json({
    windows: {
      state: "ready",
      sources: Array.from({ length: 59 }, (_, index) => ({
        id: index === 0 ? "window:fixture" : `window:other-${index}`,
        application: index === 0 ? "Fixture" : "Other Mac app",
        title: "Mac source",
        contentWidth: 600,
        contentHeight: 400,
      })),
    },
  }),
);
// Presence is deliberately substituted; this does not establish headset availability.
app.get("/api/window-layout/availability", (_req, res) =>
  res.json({ available: true }),
);
installWindowLayoutRoutes(app, store);
const server = app.listen(0, "127.0.0.1");
await once(server, "listening");
const origin = `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`;
const coordinator = new Coordinator({
  home,
  configFile,
  service: {
    info: async () => ({ capabilities: ["coordinator-workers-v1"] }),
    request: async (route: string) => {
      assert.ok(
        route.startsWith("/workers?"),
        "Window questions/naming must not dispatch worker actions",
      );
      return { workers: [] };
    },
  } as any,
  logger: { info() {}, warn() {}, error() {} } as any,
  previewCommand: process.execPath,
  previewArgs: [],
});
const config = { origin, hostId, clientId, token: "disposable-fixture-token" };
async function ask(text: string, launcherNames: string[] = []) {
  const id = randomUUID();
  await coordinator.submit(
    config,
    {
      requestId: id,
      text,
      sessionId,
      workspaceId: "fixture",
    },
    launcherNames,
  );
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    const status = await coordinator.status(clientId);
    if (status.status !== "running") {
      assert.equal(status.status, "completed", status.reply);
      return status;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Model probe timed out");
}
try {
  const count = await ask("How many windows are open here?");
  assert.match(count.reply ?? "", /\b(2|two)\b/i);
  assert.doesNotMatch(count.reply ?? "", /\b59\b/);
  assert.ok(routes.includes("GET /api/window-layout"));
  console.log(
    "PASS: live model counts the two SlopZooka content windows, not 59 Mac capture sources",
  );
  const before = await store.get(clientId);
  const ambiguous = await ask("Let us preview the login check.");
  assert.deepEqual(
    await store.get(clientId),
    before,
    "An unmatched preview must not alias an unrelated source",
  );
  assert.match(
    ambiguous.reply ?? "",
    /which|what|couldn.t find|not (found|available)|can.t (find|identify)|no .*match|don.t see|do you mean/i,
  );
  console.log(
    "PASS: an unmatched preview request leaves the layout untouched and asks for a source or reports the missing target",
  );
  await ask("Name this terminal the nice window.");
  assert.equal(title, "the-nice-window");
  console.log(
    "PASS: captured terminal renamed through its SlopZooka session endpoint without worker dispatch",
  );
  const renamed = await ask("Rename the Fixture preview to Login check.");
  assert.equal((await store.get(clientId)).windows[1].name, "Login check");
  assert.equal(renamed.turns?.length, 4);
  assert.equal(renamed.turns?.[0].text, "How many windows are open here?");
  console.log(
    "PASS: preview renamed through the existing layout owner; all four exchanges retained",
  );
  const remembered = await ask("What did you name the terminal?");
  assert.match(remembered.reply ?? "", /the[- ]nice[- ]window/i);
  console.log(
    "PASS: follow-up retains conversation and current SlopZooka naming context",
  );
  const aliases = await ask(
    "Which two launcher repos do I mean by Poncho two and Slop Zuka? Give their exact full names.",
    ["merit-systems/poncho2", "sragss/SlopZooka"],
  );
  assert.match(aliases.reply ?? "", /merit-systems\/poncho2/i);
  assert.match(aliases.reply ?? "", /sragss\/slopzooka/i);
  console.log("PASS: spoken repo names resolve to both exact launcher entries");
} finally {
  coordinator.close();
  server.closeAllConnections();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await fs.rm(home, { recursive: true, force: true });
}
