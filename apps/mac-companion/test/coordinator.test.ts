import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import express from "express";
import { createModels } from "@earendil-works/pi-ai";
import {
  fauxProvider,
  fauxAssistantMessage,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { Coordinator } from "../src/coordinator.js";
import { normalizedName } from "../src/names.js";
const clientId = randomUUID();
const log = { info() {}, warn() {}, error() {} };
const turn = (name: string, args: unknown, id = "call-1") =>
  fauxAssistantMessage([fauxToolCall(name, args as any, { id })], {
    stopReason: "toolUse",
  });
const until = async (fn: () => Promise<boolean>) => {
  for (let i = 0; i < 100; i++) {
    if (await fn()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("Condition timed out");
};
async function fixture(
  responses: any[],
  serviceRequest: (path: string, method?: string, body?: any) => Promise<any>,
  handler?: (app: express.Express) => void,
) {
  const home = await fs.mkdtemp("/tmp/slz-coordinator-test-");
  const configFile = home + "/config.json";
  await fs.writeFile(
    configFile,
    JSON.stringify({
      model: "gpt-5.6-sol",
      apiKey: "test-not-a-key",
      codexExecutable: "/test/codex",
    }),
    { mode: 0o600 },
  );
  const app = express();
  app.use(express.json());
  handler?.(app);
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const faux = fauxProvider(),
    models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses(responses);
  const modelContexts: any[] = [];
  const coordinator = new Coordinator({
    home,
    configFile,
    service: {
      info: async () => ({ capabilities: ["coordinator-workers-v1"] }),
      request: serviceRequest,
    } as any,
    logger: log,
    previewCommand: process.execPath,
    previewArgs: [],
    inference: {
      model: faux.getModel(),
      streamFn: (model, context, options) => {
        modelContexts.push(structuredClone(context));
        return models.streamSimple(model, context, options);
      },
    },
  });
  const config = {
    origin: `http://127.0.0.1:${(server.address() as any).port}`,
    clientId,
    hostId: randomUUID(),
    token: "fixture-token",
  };
  return {
    coordinator,
    modelContexts,
    config,
    home,
    close: async () => {
      coordinator.close();
      server.closeAllConnections();
      await new Promise<void>((r) => server.close(() => r()));
      await fs.rm(home, { recursive: true, force: true });
    },
  };
}
test("real Pi loop retains captured destination, deduplicates a retried request and rejects cross-client worker routing", async () => {
  const writes: any[] = [];
  const f = await fixture(
    [
      turn("worker_submit", {
        sessionId: "foreign-worker",
        text: "wrong",
        mode: "queue",
      }),
    ],
    async (route, method, body) => {
      if (method === "POST") writes.push({ route, body });
      return {
        workers: [
          {
            sessionId: "our-worker",
            workspaceId: "one",
            status: "idle",
            deliveries: [],
          },
        ],
      };
    },
  );
  try {
    const request = {
      requestId: randomUUID(),
      text: "Send to the selected worker",
      sessionId: "our-worker",
    };
    await f.coordinator.submit(f.config, request);
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    assert.equal(writes.length, 0);
    assert.equal((await f.coordinator.status(clientId)).status, "failed");
    assert.match(
      (await f.coordinator.status(clientId)).reply!,
      /no worker binding/,
    );
    await f.coordinator.submit(f.config, request);
    assert.equal(writes.length, 0);
    await assert.rejects(
      f.coordinator.submit(f.config, { ...request, text: "changed" }),
      /different content/,
    );
    await assert.rejects(
      f.coordinator.answer(clientId, "foreign-worker", "1", true),
      /does not belong/,
    );
  } finally {
    await f.close();
  }
});
test("Stop during workspace creation prevents later rename and preserves the accepted partial resource", async () => {
  let release!: () => void,
    created = 0,
    renamed = 0;
  const gate = new Promise<void>((r) => {
    release = r;
  });
  const f = await fixture(
    [turn("workspace_launch", { project: "test/fixture", name: "Purpose" })],
    async () => ({ workers: [] }),
    (app) => {
      app.post("/api/workspaces/launch", async (_req, res) => {
        created++;
        await gate;
        res.json({ workspaceId: "created" });
      });
      app.patch("/api/workspaces/created", (_req, res) => {
        renamed++;
        res.json({});
      });
    },
  );
  try {
    const request = { requestId: randomUUID(), text: "Launch fixture" };
    await f.coordinator.submit(f.config, request);
    await until(async () => created === 1);
    await f.coordinator.stop(clientId);
    release();
    await until(
      async () => (await f.coordinator.status(clientId)).status === "stopped",
    );
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(created, 1);
    assert.equal(renamed, 0);
    assert.match((await f.coordinator.status(clientId)).reply!, /Stopped/);
    await f.coordinator.submit(f.config, request);
    assert.equal(created, 1);
  } finally {
    release();
    await f.close();
  }
});
test("Stop scopes cancellation to the submitted request and blocks the next queued model tool", async () => {
  let release!: (x: unknown) => void;
  const gate = new Promise((r) => {
    release = r;
  });
  const calls: any[] = [];
  const f = await fixture(
    [
      fauxAssistantMessage(
        [
          fauxToolCall(
            "worker_submit",
            { sessionId: "ours", text: "first", mode: "queue" },
            { id: "a" },
          ),
          fauxToolCall(
            "worker_submit",
            { sessionId: "ours", text: "second", mode: "queue" },
            { id: "b" },
          ),
        ],
        { stopReason: "toolUse" },
      ),
    ],
    async (route, method, body) => {
      if (route.startsWith("/workers?"))
        return {
          workers: [
            {
              sessionId: "ours",
              workspaceId: "one",
              status: "idle",
              deliveries: [],
            },
          ],
        };
      calls.push({ route, method, body });
      if (route.endsWith("/submit")) return gate;
      return {};
    },
  );
  try {
    await f.coordinator.submit(f.config, {
      requestId: randomUUID(),
      text: "Do the tasks",
      sessionId: "ours",
    });
    await until(async () => calls.some((c) => c.route.endsWith("/submit")));
    await f.coordinator.stop(clientId);
    release({ status: "queued" });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(calls.filter((c) => c.route.endsWith("/submit")).length, 1);
    const stop = calls.find((c) => c.route.endsWith("/stop"));
    assert.equal(stop.route, "/workers/ours/stop");
    assert.equal(stop.body.requestIds.length, 1);
    const stopped = await f.coordinator.status(clientId);
    assert.equal(stopped.status, "stopped");
    assert.deepEqual(stopped.workerSessionIds, ["ours"]);
    assert.match(stopped.reply!, /Stopped this request/);
  } finally {
    release({});
    await f.close();
  }
});

test("coordinator routes require pairing and capture the native client and destination", async () => {
  const { Pairing } = await import("../src/auth.js");
  const { installCoordinatorRoutes } = await import(
    "../src/coordinator-http.js"
  );
  const home = await fs.mkdtemp("/tmp/slz-coordinator-http-");
  const app = express();
  app.use(express.json());
  const pairing = new Pairing(home);
  pairing.install(app);
  const calls: any[] = [];
  const coordinator = {
    status: async (id: string) => ({ clientId: id, workers: [] }),
    submit: async (config: any, request: any) => {
      calls.push({ config, request });
      return { status: "running", requestId: request.requestId };
    },
    stop: async (id: string) => ({ clientId: id, status: "stopped" }),
    answer: async (...args: any[]) => {
      calls.push({ answer: args });
    },
  } as any;
  installCoordinatorRoutes(
    app,
    coordinator,
    pairing.hostId,
    "http://127.0.0.1:7777",
  );
  app.use(
    (
      error: any,
      _req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      res.status(error.statusCode ?? 400).json({ error: "Rejected" });
    },
  );
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const origin = `http://127.0.0.1:${(server.address() as any).port}`;
  try {
    for (const [route, method] of [
      ["", "GET"],
      ["", "POST"],
      ["/stop", "POST"],
      ["/answer", "POST"],
    ]) {
      assert.equal(
        (await fetch(origin + "/api/coordinator" + route, { method })).status,
        401,
      );
    }
    const pair = (await fetch(origin + "/api/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: pairing.code }),
    }).then((r) => r.json())) as any;
    const headers = {
      Authorization: `Bearer ${pair.token}`,
      "Content-Type": "application/json",
      "X-SlopZooka-Client-ID": clientId,
    };
    assert.equal(
      (
        await fetch(origin + "/api/coordinator", {
          headers: { ...headers, "X-SlopZooka-Client-ID": "bad" },
        })
      ).status,
      400,
    );
    const request = {
      requestId: randomUUID(),
      text: "Prepare the selected workspace",
      workspaceId: "fixture",
      sessionId: "captured",
    };
    const response = await fetch(origin + "/api/coordinator", {
      method: "POST",
      headers,
      body: JSON.stringify(request),
    });
    assert.equal(response.status, 200);
    assert.ok(!(await response.text()).includes(pair.token));
    assert.deepEqual(calls[0].request, request);
    assert.equal(calls[0].config.clientId, clientId);
    assert.equal(calls[0].config.token, pair.token);
    const other = randomUUID();
    assert.equal(
      (
        (await fetch(origin + "/api/coordinator", {
          headers: { ...headers, "X-SlopZooka-Client-ID": other },
        }).then((r) => r.json())) as any
      ).clientId,
      other,
    );
  } finally {
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("uncertain Stop stays visible and retries only the same owned submissions", async () => {
  let failStop = true;
  const stops: any[] = [];
  const f = await fixture(
    [turn("worker_submit", { sessionId: "ours", text: "wait", mode: "queue" })],
    async (route, _method, body) => {
      if (route.startsWith("/workers?"))
        return {
          workers: [
            {
              sessionId: "ours",
              workspaceId: "one",
              status: "running",
              deliveries: [],
            },
          ],
        };
      if (route.endsWith("/stop")) {
        stops.push(body);
        if (failStop) throw new Error("lost reply");
      }
      return { status: "running" };
    },
  );
  try {
    await f.coordinator.submit(f.config, {
      requestId: randomUUID(),
      text: "Wait",
      sessionId: "ours",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    await assert.rejects(
      f.coordinator.stop(clientId),
      /could not be confirmed/,
    );
    const uncertain = await f.coordinator.status(clientId);
    assert.equal(uncertain.status, "failed");
    assert.match(uncertain.reply!, /may still be working/);
    failStop = false;
    assert.equal((await f.coordinator.stop(clientId)).status, "stopped");
    assert.deepEqual(stops[0], stops[1]);
  } finally {
    await f.close();
  }
});

test("new requests cannot replace ownership while Stop is awaiting confirmation", async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let stopping = false;
  const f = await fixture(
    [turn("worker_submit", { sessionId: "ours", text: "wait", mode: "queue" })],
    async (route) => {
      if (route.startsWith("/workers?"))
        return {
          workers: [
            {
              sessionId: "ours",
              workspaceId: "one",
              status: "running",
              deliveries: [],
            },
          ],
        };
      if (route.endsWith("/stop")) {
        stopping = true;
        await gate;
      }
      return { status: "running" };
    },
  );
  try {
    const requestId = randomUUID();
    await f.coordinator.submit(f.config, {
      requestId,
      text: "Wait",
      sessionId: "ours",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    const stop = f.coordinator.stop(clientId);
    await until(async () => stopping);
    await assert.rejects(
      f.coordinator.submit(f.config, {
        requestId: randomUUID(),
        text: "Another task",
      }),
      /busy/,
    );
    await assert.rejects(f.coordinator.stop(clientId), /still being confirmed/);
    assert.equal((await f.coordinator.status(clientId)).requestId, requestId);
    release();
    assert.equal((await stop).status, "stopped");
  } finally {
    release();
    await f.close();
  }
});

test("SlopZooka context and rename use headset identities, not Mac capture windows or worker delegation", async () => {
  const { WindowLayoutStore, installWindowLayoutRoutes } = await import(
    "../src/window-layout.js"
  );
  const home = await fs.mkdtemp("/tmp/slz-coordinator-layout-");
  const store = new WindowLayoutStore(home);
  const original = {
    version: 1 as const,
    revision: 0,
    windows: [
      {
        id: "terminal-one",
        kind: "terminal" as const,
        targetID: "session-one",
      },
      {
        id: "preview-one",
        kind: "preview" as const,
        targetID: "window:fixture",
        name: "Fixture",
      },
    ],
  };
  await store.put(clientId, original.revision, original.windows);
  const renamed: any[] = [];
  const serviceWrites: string[] = [];
  let currentName = "Shell";
  const fixtureHost = randomUUID();
  let observedClient: string | undefined;
  const f = await fixture(
    [
      turn("context_get", {}),
      turn(
        "window_rename",
        { windowId: "terminal-one", name: "The nice window" },
        "rename",
      ),
      turn(
        "window_rename",
        { windowId: "preview-one", name: "Login preview" },
        "preview",
      ),
      turn("context_get", {}, "verify"),
      fauxAssistantMessage("Named **The nice window** and **Login preview**."),
      turn(
        "window_rename",
        { windowId: "not-on-this-headset", name: "Wrong" },
        "wrong",
      ),
    ],
    async (route, method) => {
      if (method) serviceWrites.push(route);
      return { workers: [] };
    },
    (app) => {
      app.get("/health", (_req, res) => res.json({ hostId: fixtureHost }));
      app.get("/api/frontends", (_req, res) =>
        res.json({
          windows: {
            sources: [
              { id: "window:fixture", application: "Fixture", title: "Login" },
              { id: "window:unrelated", application: "iTerm", title: "Other" },
            ],
          },
        }),
      );
      app.get("/api/repos/recent", (_req, res) => res.json({ repos: [] }));
      app.get("/api/workspaces", (_req, res) =>
        res.json({ workspaces: [{ workspaceId: "one", name: "Login" }] }),
      );
      app.get("/api/sessions", (_req, res) =>
        res.json({
          sessions: [
            {
              id: "session-one",
              workspaceId: "one",
              title: "Shell",
              name: currentName,
            },
          ],
        }),
      );
      app.patch("/api/sessions/session-one", (req, res) => {
        renamed.push(req.body);
        currentName = normalizedName(req.body.name);
        res.json({
          session: { id: "session-one", title: "Shell", name: currentName },
        });
      });
      app.get("/api/window-layout", (req, _res, next) => {
        observedClient = req.header("X-SlopZooka-Client-ID");
        next();
      });
      // Substitute headset presence only; the real revision-checked layout owner handles all writes.
      app.get("/api/window-layout/availability", (_req, res) =>
        res.json({ available: true }),
      );
      installWindowLayoutRoutes(app, store);
    },
  );
  f.config.hostId = fixtureHost;
  try {
    const requestId = randomUUID();
    await f.coordinator.submit(f.config, {
      requestId,
      text: "Name my windows",
      sessionId: "session-one",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    const status = await f.coordinator.status(clientId);
    assert.equal(status.status, "completed", JSON.stringify(status));
    assert.equal(observedClient, clientId);
    assert.deepEqual(renamed, [{ name: "The nice window" }]);
    assert.equal(
      serviceWrites.length,
      0,
      "No task is delegated for SlopZooka window naming",
    );
    assert.equal((await store.get(clientId)).windows[1].name, "Login preview");
    const results = f.modelContexts
      .flatMap((c) => c.messages)
      .filter((m) => m.role === "toolResult" && m.toolName === "context_get");
    const context = JSON.parse(results.at(-1).content[0].text);
    assert.equal(context.surface, "SlopZooka Ask on Apple Vision Pro");
    assert.equal(context.headsetWindows.windows.length, 2);
    assert.equal(
      context.headsetWindows.windows[1].source.application,
      "Fixture",
    );
    assert.ok(
      !JSON.stringify(context).includes("window:unrelated"),
      "Unshared Mac sources are not headset window context",
    );
    assert.equal(
      context.headsetWindows.windows[0].session.name,
      "The-nice-window",
    );
    assert.equal(context.headsetWindows.windows[1].name, "Login preview");
    assert.match(
      context.headsetWindows.semantics,
      /not observed physical visibility/,
    );
    assert.deepEqual(context.selected, { sessionId: "session-one" });
    assert.equal(status.turns?.[0].text, "Name my windows");
    await f.coordinator.submit(f.config, {
      requestId,
      text: "Name my windows",
      sessionId: "session-one",
    });
    assert.equal(
      (await f.coordinator.status(clientId)).turns?.length,
      1,
      "Retry does not duplicate conversation entries",
    );
    assert.equal(
      (await f.coordinator.status(randomUUID())).turns?.length,
      0,
      "Conversation remains headset-client scoped",
    );
    await f.coordinator.submit(f.config, {
      requestId: randomUUID(),
      text: "Rename an absent window",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    const history = (await f.coordinator.status(clientId)).turns!;
    assert.equal(history.length, 2);
    assert.equal(history[0].status, "completed");
    assert.match(history[0].reply!, /nice window/);
    assert.equal(history[1].status, "failed");
    assert.equal(
      renamed.length,
      1,
      "An absent/other-client window cannot rename a session",
    );
  } finally {
    await f.close();
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("conversation progress stays attached to each delivery when a worker is reused", async () => {
  const deliveries: any[] = [];
  const worker = {
    sessionId: "ours",
    workspaceId: "one",
    status: "running",
    result: undefined as string | undefined,
    deliveries,
  };
  const f = await fixture(
    [
      turn("worker_submit", {
        sessionId: "ours",
        text: "first",
        mode: "queue",
      }),
      fauxAssistantMessage("Started the first task."),
      turn(
        "worker_submit",
        { sessionId: "ours", text: "second", mode: "queue" },
        "second",
      ),
      fauxAssistantMessage("Started the second task."),
    ],
    async (route, _method, body) => {
      if (route.startsWith("/workers?")) return { workers: [worker] };
      if (route.endsWith("/submit")) {
        worker.status = "running";
        worker.result = undefined;
        deliveries.push({ requestId: body.requestId, status: "running" });
      }
      if (route.endsWith("/stop"))
        for (const d of deliveries)
          if (body.requestIds.includes(d.requestId)) d.status = "interrupted";
      return { status: "running" };
    },
  );
  try {
    await f.coordinator.submit(f.config, {
      requestId: randomUUID(),
      text: "First",
      sessionId: "ours",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    deliveries[0].status = "completed";
    worker.status = "completed";
    worker.result =
      "First **passed**.\n\nLong supporting details stay in the terminal.";
    await f.coordinator.submit(f.config, {
      requestId: randomUUID(),
      text: "Second",
      sessionId: "ours",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    assert.deepEqual(
      (await f.coordinator.status(clientId)).turns?.map((t) => t.workStatus),
      ["completed", "running"],
    );
    await f.coordinator.stop(clientId);
    const turns = (await f.coordinator.status(clientId)).turns!;
    assert.deepEqual(
      turns.map((t) => t.workStatus),
      ["completed", "interrupted"],
    );
    assert.equal(turns[0].reply, "Started the first task.");
    assert.equal(turns[1].status, "stopped");
    assert.equal(turns[0].resultExcerpt, "First **passed**.");
    assert.equal(
      turns[1].resultExcerpt,
      undefined,
      "An interrupted turn cannot inherit the prior task's result",
    );
    deliveries.shift();
    const retained = (await f.coordinator.status(clientId)).turns![0];
    assert.equal(
      retained.workStatus,
      "completed",
      "Worker snapshot eviction cannot rewrite conversation history",
    );
    assert.equal(retained.resultExcerpt, "First **passed**.");
  } finally {
    await f.close();
  }
});

test("bounded model tool history preserves the visible conversation and target context", async () => {
  const f = await fixture(
    Array.from({ length: 43 }, () => fauxAssistantMessage("Noted.")),
    async () => ({ workers: [] }),
  );
  try {
    for (let index = 0; index < 43; index++) {
      await f.coordinator.submit(f.config, {
        requestId: randomUUID(),
        text: index === 0 ? "Remember the name Iris" : `Follow-up ${index}`,
        workspaceId: "iris-workspace",
      });
      await until(
        async () => (await f.coordinator.status(clientId)).status !== "running",
      );
    }
    const status = await f.coordinator.status(clientId);
    assert.equal(status.turns?.length, 43);
    const context = JSON.stringify(f.modelContexts.at(-1).messages);
    assert.match(context, /Earlier conversation excerpts/);
    assert.match(context, /Remember the name Iris/);
    assert.match(context, /iris-workspace/);
  } finally {
    await f.close();
  }
});
