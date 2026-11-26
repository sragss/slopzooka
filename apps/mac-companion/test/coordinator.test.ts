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
import type { LogFields } from "../src/log-events.js";
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
  const events: { event: string; fields?: LogFields }[] = [];
  const record = (event: string, fields?: LogFields) => {
    events.push({ event, fields });
  };
  const coordinator = new Coordinator({
    home,
    configFile,
    service: {
      info: async () => ({ capabilities: ["coordinator-workers-v1"] }),
      request: serviceRequest,
    } as any,
    logger: { info: record, warn: record, error: record },
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
    events,
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
    // A retry may reconstruct the same captured fields in a different order.
    await f.coordinator.submit(f.config, {
      sessionId: request.sessionId,
      text: request.text,
      requestId: request.requestId,
    });
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
test("Ask opens the original saved thread and presents the actual reused terminal", async () => {
  const threadId = randomUUID(),
    hostId = randomUUID();
  let resumed = 0;
  let shown: any;
  const f = await fixture(
    [turn("thread_open", { threadId })],
    async () => ({ workers: [] }),
    (app) => {
      app.post(`/api/codex/threads/${threadId}/resume`, (req, res) => {
        assert.ok(req.body.sessionId);
        resumed++;
        res.json({ session: { id: "reused" } });
      });
      app.get("/health", (_req, res) => res.json({ hostId }));
      app.get("/api/sessions", (_req, res) =>
        res.json({ sessions: [{ id: "reused" }] }),
      );
      app.get("/api/window-layout", (_req, res) =>
        res.json({ version: 1, revision: 0, windows: [] }),
      );
      app.get("/api/window-layout/availability", (_req, res) =>
        res.json({ available: true }),
      );
      app.put("/api/window-layout", (req, res) => {
        shown = req.body.windows;
        res.json({ ...req.body, revision: 1 });
      });
    },
  );
  try {
    f.config.hostId = hostId;
    const request = {
      requestId: randomUUID(),
      text: "Pull up that saved thread",
    };
    await f.coordinator.submit(f.config, request);
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    await f.coordinator.submit(f.config, request);
    assert.equal(resumed, 1);
    assert.deepEqual(shown, [
      { id: "reused", kind: "terminal", targetID: "reused" },
    ]);
  } finally {
    await f.close();
  }
});
test("a new project uses local repo creation and returns its existing first worktree to Pi", async () => {
  const calls: string[] = [];
  const f = await fixture(
    [turn("repo_create_local", { name: "Email Test" })],
    async () => ({ workers: [] }),
    (app) => {
      app.post("/api/repos/local", (req, res) => {
        calls.push(req.body.repoName);
        res.status(201).json({
          repo: { nameWithOwner: "~local/email-test" },
          workspaceId: "first",
          worktreePath: "/tmp/email-test",
        });
      });
    },
  );
  try {
    await f.coordinator.submit(f.config, {
      requestId: randomUUID(),
      text: "Create a new project called Email Test",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    assert.deepEqual(calls, ["Email Test"]);
    const result = f.modelContexts
      .flatMap((context) => context.messages)
      .find(
        (m) => m.role === "toolResult" && m.toolName === "repo_create_local",
      );
    assert.equal(JSON.parse(result.content[0].text).worktreeId, "first");
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
    [turn("worktree_launch", { repo: "test/fixture", name: "Purpose" })],
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
    await f.coordinator.stop(clientId, request.requestId);
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
test("Stop Ask lets an in-flight submission finish and blocks the next coordinator tool", async () => {
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
    const requestId = randomUUID();
    await f.coordinator.submit(f.config, {
      requestId,
      text: "Do the tasks",
      sessionId: "ours",
    });
    await until(async () => calls.some((c) => c.route.endsWith("/submit")));
    await f.coordinator.stop(clientId, requestId);
    release({ status: "queued" });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(calls.filter((c) => c.route.endsWith("/submit")).length, 1);
    assert.ok(!calls.some((c) => c.route.endsWith("/stop")));
    const stopped = await f.coordinator.status(clientId);
    assert.equal(stopped.status, "stopped");
    assert.deepEqual(stopped.workerSessionIds, ["ours"]);
    assert.match(stopped.reply!, /Stopped Ask/);
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
    stop: async (id: string, requestId: string) => {
      calls.push({ stop: { clientId: id, requestId } });
      return { clientId: id, status: "stopped" };
    },
    stopAgent: async (id: string, requestId: string) => {
      calls.push({ stopAgent: { clientId: id, requestId } });
      return { clientId: id, status: "completed" };
    },
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
      ["/stop-coordinator", "POST"],
      ["/stop-agent", "POST"],
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
    const stop = (body: unknown, action = "stop-coordinator") =>
      fetch(origin + "/api/coordinator/" + action, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      });
    assert.equal(
      (await stop({})).status,
      400,
      "Untargeted cancellation is rejected",
    );
    assert.equal((await stop({ requestId: "not-an-id" })).status, 400);
    assert.equal(calls.length, 1);
    assert.equal((await stop({ requestId: request.requestId })).status, 200);
    assert.deepEqual(calls[1].stop, { clientId, requestId: request.requestId });
    assert.equal((await stop({}, "stop-agent")).status, 400);
    assert.equal(
      (await stop({ requestId: request.requestId }, "stop-agent")).status,
      200,
    );
    assert.deepEqual(calls[2].stopAgent, {
      clientId,
      requestId: request.requestId,
    });
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
    const requestId = randomUUID();
    await f.coordinator.submit(f.config, {
      requestId,
      text: "Wait",
      sessionId: "ours",
    });
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    const before = await f.coordinator.status(clientId);
    const uncertain = await f.coordinator.stopAgent(clientId, requestId);
    assert.equal(uncertain.status, before.status);
    assert.equal(uncertain.reply, before.reply);
    assert.equal(uncertain.turns![0].canStopAgent, true);
    assert.match(uncertain.turns![0].agentStopError!, /Could not confirm/);
    failStop = false;
    const retried = await f.coordinator.stopAgent(clientId, requestId);
    assert.equal(retried.turns![0].agentStopError, undefined);
    assert.deepEqual(stops[0], stops[1]);
  } finally {
    await f.close();
  }
});

test("Ask can accept a new request while Stop agent is awaiting confirmation", async () => {
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
    const stop = f.coordinator.stopAgent(clientId, requestId);
    await until(async () => stopping);
    const nextId = randomUUID();
    await f.coordinator.submit(f.config, {
      requestId: nextId,
      text: "Another task",
    });
    await assert.rejects(
      f.coordinator.stopAgent(clientId, requestId),
      /still being confirmed/,
    );
    assert.equal((await f.coordinator.status(clientId)).requestId, nextId);
    release();
    const result = await stop;
    assert.equal(result.requestId, nextId);
    assert.equal(
      result.turns?.find((turn) => turn.requestId === requestId)
        ?.agentStopError,
      undefined,
    );
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
    const outcomes = f.events.filter(
      (e) =>
        e.event === "coordinator.tool.completed" &&
        e.fields?.requestId === requestId,
    );
    assert.ok(
      outcomes.some(
        (e) => e.fields?.tool === "context_get" && e.fields?.windowCount === 2,
      ),
    );
    assert.deepEqual(
      outcomes
        .filter((e) => e.fields?.tool === "window_rename")
        .map((e) => e.fields?.windowKind)
        .sort(),
      ["preview", "terminal"],
    );
    assert.doesNotMatch(
      JSON.stringify(f.events),
      /Name my windows|Login preview|The-nice-window/i,
    );
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
  let workerPresent = true;
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
      turn(
        "worker_submit",
        { sessionId: "ours", text: "check", mode: "queue" },
        "check",
      ),
      fauxAssistantMessage("Started the second task."),
    ],
    async (route, _method, body) => {
      if (route.startsWith("/workers?"))
        return { workers: workerPresent ? [worker] : [] };
      if (route.endsWith("/submit")) {
        worker.status = "running";
        worker.result = undefined;
        deliveries.push({
          requestId: body.requestId,
          status: body.text === "check" ? "queued" : "running",
        });
        return worker;
      }
      if (route.endsWith("/stop"))
        for (const d of deliveries)
          if (
            body.requestIds.includes(d.requestId) &&
            ["running", "queued"].includes(d.status)
          )
            d.status = "interrupted";
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
    const secondRequestId = randomUUID();
    await f.coordinator.submit(f.config, {
      requestId: secondRequestId,
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
    const receipts = f.events.filter(
      (e) =>
        e.event === "coordinator.tool.completed" &&
        e.fields?.tool === "worker_submit",
    );
    assert.deepEqual(
      receipts.map((e) => e.fields?.status),
      ["running", "running", "queued"],
    );
    assert.equal(receipts[2]?.fields?.deliveryId, deliveries[2].requestId);
    const lastMessage = f.modelContexts.at(-1).messages.at(-1);
    assert.match(JSON.stringify(lastMessage.content), /queued/);
    assert.doesNotMatch(JSON.stringify(lastMessage.content), /"deliveries"/);
    deliveries[1].status = "failed";
    deliveries[2].status = "queued";
    const mixed = (await f.coordinator.status(clientId)).turns!;
    assert.equal(mixed[0].hasActiveWork, false);
    assert.equal(mixed[1].workStatus, "failed");
    assert.equal(
      mixed[1].hasActiveWork,
      true,
      "A failure cannot hide queued work owned by this request",
    );
    workerPresent = false;
    const missing = (await f.coordinator.status(clientId)).turns!;
    assert.equal(missing[0].resultExcerpt, "First **passed**.");
    assert.equal(
      missing[1].workStatus,
      "unavailable",
      "A missing worker cannot confirm previously running work",
    );
    assert.equal(missing[1].hasActiveWork, false);
    workerPresent = true;
    deliveries[2].status = "running";
    assert.equal(
      (await f.coordinator.status(clientId)).turns![1].hasActiveWork,
      true,
    );
    await f.coordinator.stopAgent(clientId, secondRequestId);
    const turns = (await f.coordinator.status(clientId)).turns!;
    assert.deepEqual(
      turns.map((t) => t.workStatus),
      ["completed", "failed"],
    );
    assert.equal(turns[1].hasActiveWork, false);
    assert.equal(deliveries[2].status, "interrupted");
    assert.equal(turns[0].reply, "Started the first task.");
    assert.equal(turns[1].status, "completed");
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

test("a stale Stop Ask cannot cancel a newer request and Stop agent can target history", async () => {
  const stops: any[] = [];
  const submissions: string[] = [];
  const f = await fixture(
    [
      turn("worker_submit", {
        sessionId: "ours",
        text: "first",
        mode: "queue",
      }),
      fauxAssistantMessage("First task accepted."),
      turn("worker_submit", {
        sessionId: "ours",
        text: "second",
        mode: "queue",
      }),
      fauxAssistantMessage("Second task accepted."),
    ],
    async (route, _method, body) => {
      if (route.startsWith("/workers?"))
        return {
          workers: [
            {
              sessionId: "ours",
              workspaceId: "one",
              status: "running",
              deliveries: submissions.map((requestId) => ({
                requestId,
                status: "running",
              })),
            },
          ],
        };
      if (route.endsWith("/stop")) stops.push(body);
      if (route.endsWith("/submit")) submissions.push(body.requestId);
      return { status: "running" };
    },
  );
  try {
    const first = { requestId: randomUUID(), text: "First", sessionId: "ours" };
    const second = {
      requestId: randomUUID(),
      text: "Second",
      sessionId: "ours",
    };
    await f.coordinator.submit(f.config, first);
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    await f.coordinator.submit(f.config, second);
    await until(
      async () => (await f.coordinator.status(clientId)).status !== "running",
    );
    await assert.rejects(
      f.coordinator.stop(clientId, first.requestId),
      /request changed/i,
    );
    assert.equal(
      stops.length,
      0,
      "A stale Stop must reach neither the worker nor the new request",
    );
    const current = await f.coordinator.status(clientId);
    assert.equal(current.requestId, second.requestId);
    assert.equal(current.status, "completed");
    await assert.rejects(
      f.coordinator.stop(clientId, second.requestId),
      /finished processing/,
    );
    await assert.rejects(
      f.coordinator.stopAgent(randomUUID(), first.requestId),
      /No delegated agent work/,
    );
    assert.equal(current.turns?.[0].canStopAgent, true);
    await f.coordinator.stopAgent(clientId, first.requestId);
    assert.equal(submissions.length, 2);
    assert.deepEqual(stops, [{ requestIds: [submissions[0]] }]);
  } finally {
    await f.close();
  }
});

test("queued voice turns keep arrival order, captured destination and launcher names through a retry", async () => {
  let release!: () => void;
  const gate = new Promise<void>((done) => {
    release = done;
  });
  const f = await fixture(
    [
      turn("worker_submit", { sessionId: "ours", text: "hold", mode: "queue" }),
      fauxAssistantMessage("First done."),
      fauxAssistantMessage("Second done."),
      fauxAssistantMessage("Third done."),
    ],
    async (route) => {
      if (route.startsWith("/workers?"))
        return {
          workers: [
            {
              sessionId: "ours",
              workspaceId: "first",
              status: "idle",
              deliveries: [],
            },
          ],
        };
      await gate;
      return { status: "running" };
    },
  );
  try {
    const [a, b, c] = ["First", "Poncho two", "Slop Zuka"].map((text) => ({
      requestId: randomUUID(),
      text,
      workspaceId: text,
    }));
    await f.coordinator.submit(f.config, a!);
    await f.coordinator.submit(f.config, b!, ["owner/poncho2"]);
    const queued = await f.coordinator.submit(f.config, c!, [
      "owner/SlopZooka",
    ]);
    assert.equal(queued.requestId, a!.requestId);
    assert.deepEqual(
      queued.turns?.map((t) => t.status),
      ["running", "queued", "queued"],
    );
    await f.coordinator.submit(f.config, b!, ["updated launcher"]);
    release();
    await until(
      async () =>
        (await f.coordinator.status(clientId)).turns?.every(
          (t) => t.status === "completed",
        ) === true,
    );
    const turns = (await f.coordinator.status(clientId)).turns!;
    assert.deepEqual(
      turns.map((t) => t.reply),
      ["First done.", "Second done.", "Third done."],
    );
    assert.deepEqual(
      turns.map((t) => t.workspaceId),
      ["First", "Poncho two", "Slop Zuka"],
    );
    assert.match(JSON.stringify(f.modelContexts.at(-1)), /owner\/SlopZooka/);
    assert.doesNotMatch(JSON.stringify(f.modelContexts), /updated launcher/);
  } finally {
    release();
    await f.close();
  }
});
