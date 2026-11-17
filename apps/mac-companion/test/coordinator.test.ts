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
      streamFn: models.streamSimple.bind(models),
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
