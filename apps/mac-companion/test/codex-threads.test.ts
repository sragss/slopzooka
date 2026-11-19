import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { once } from "node:events";
import express from "express";
import { CodexThreads } from "../src/codex-threads.js";
import { headsetCodexLaunch } from "../src/preview-launch.js";
import { readPreviewConfig } from "../src/preview-control.js";
import { installCodexThreadRoutes } from "../src/codex-http.js";
import { SessionServiceClient } from "../src/session-service-client.js";
import { createDiagnostics } from "../src/logger.js";
import { ServiceError } from "../src/errors.js";
import { SESSION_SERVICE_VERSION } from "../src/session-service-protocol.js";

const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
const fixture = path.resolve(import.meta.dirname, "fixtures/codex.mjs");
async function setup() {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-codex-"));
  await fs.mkdir(path.join(home, "project"));
  const diagnostics = createDiagnostics("mac-companion", { home });
  const environment = {
    ...process.env,
    SHELL: "/bin/sh",
    CODEX_HOME: home,
    SLOPZOOKA_CODEX_COMMAND: `${quote(process.execPath)} ${quote(fixture)}`,
  };
  return {
    home,
    diagnostics,
    environment,
    calls: async () =>
      (await fs.readFile(path.join(home, "calls.jsonl"), "utf8"))
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line)),
    clean: async () => {
      await diagnostics.store.flush();
      await fs.rm(home, { recursive: true, force: true });
    },
  };
}

test("Codex catalog requests exactly one recent page, shares concurrent reads, and projects metadata without logging titles", async () => {
  const f = await setup();
  const codex = new CodexThreads(
    f.diagnostics.logger("codex-threads"),
    f.environment,
  );
  try {
    const [a, b] = await Promise.all([codex.list(), codex.list()]);
    assert.deepEqual(a, b);
    assert.equal(a.length, 25);
    assert.equal(a[0]!.title, "Fallback title");
    assert.equal(a[2]!.available, false);
    assert.ok(a[0]!.updatedAt > a[24]!.updatedAt);
    const calls = await f.calls();
    const lists = calls.filter((call) => call.method === "thread/list");
    assert.equal(lists.length, 1);
    assert.deepEqual(lists[0].params, {
      limit: 25,
      sortKey: "updated_at",
      sortDirection: "desc",
      archived: false,
      modelProviders: [],
      sourceKinds: ["cli", "vscode", "appServer", "exec"],
    });
    const thread = await codex.read(a[1]!.id);
    assert.equal(thread.id, a[1]!.id);
    assert.deepEqual(
      (await f.calls()).find((call) => call.method === "thread/read").params,
      { threadId: a[1]!.id, includeTurns: false },
    );
    await assert.rejects(
      codex.read(a[2]!.id),
      (error: ServiceError) => error.statusCode === 409,
    );
    await assert.rejects(
      codex.read("--last"),
      (error: ServiceError) => error.statusCode === 400,
    );
    const found = await codex.page(4, "page-1", "pairing");
    assert.equal(found.nextCursor, "page-2");
    assert.equal(found.threads[0]?.id, a[4]!.id);
    const peek = await codex.peek(a[4]!.id, "newer");
    assert.deepEqual(peek, {
      turns: [{ user: "x".repeat(280), assistant: "y".repeat(280) }],
      nextCursor: "older",
    });
    const callsAfterPeek = await f.calls();
    assert.deepEqual(
      callsAfterPeek.find((c) => c.method === "thread/turns/list")?.params,
      {
        threadId: a[4]!.id,
        cursor: "newer",
        limit: 3,
        sortDirection: "desc",
        itemsView: "summary",
      },
    );
    assert.equal(
      callsAfterPeek.find((c) => c.method === "thread/search")?.params
        .searchTerm,
      "pairing",
    );
    assert.ok(!callsAfterPeek.some((c) => c.method === "thread/resume"));
    await f.diagnostics.store.flush();
    const logs = await fs.readFile(f.diagnostics.store.file, "utf8");
    assert.ok(
      !logs.includes("Private thread") &&
        !logs.includes("private conversation"),
    );
  } finally {
    codex.stop();
    await f.clean();
  }
});

for (const mode of ["hang", "exit", "oversize", "malformed"]) {
  test(`Codex ${mode} failure is bounded, private, and refreshable`, async () => {
    const f = await setup();
    const codex = new CodexThreads(
      f.diagnostics.logger("codex-threads"),
      f.environment,
      500,
    );
    try {
      await fs.writeFile(path.join(f.home, "mode"), mode);
      await assert.rejects(
        codex.list(),
        (error: ServiceError) =>
          error.statusCode === 503 && !error.message.includes("private"),
      );
      await fs.rm(path.join(f.home, "mode"));
      assert.equal((await codex.list()).length, 25);
    } finally {
      codex.stop();
      await f.clean();
    }
  });
}

test("a retained service without resume support cannot silently launch a fresh conversation", async () => {
  const f = await setup();
  const client = await SessionServiceClient.forHome(f.home);
  const paths: string[] = [];
  const server = http.createServer((req, res) => {
    paths.push(req.url!);
    res.setHeader("Content-Type", "application/json");
    res.end(
      JSON.stringify({
        version: SESSION_SERVICE_VERSION,
        capabilities: [],
        sessions: [],
      }),
    );
  });
  server.listen(client.socketPath);
  await once(server, "listening");
  try {
    await assert.rejects(
      client.create({
        id: "resume",
        workspaceId: "folder",
        cwd: f.home,
        profile: "codex",
        environment: {},
        codexResume: {
          threadId: "00000000-0000-4000-8000-000000000001",
          title: "Saved",
        },
      }),
      (error: ServiceError) =>
        error.statusCode === 503 &&
        error.message.includes("updated session service"),
    );
    await assert.rejects(
      client.create({
        id: "fresh",
        workspaceId: "folder",
        cwd: f.home,
        profile: "codex",
        environment: {},
        previewMcp: { command: process.execPath, args: ["preview.mjs"] },
      }),
      (error: ServiceError) =>
        error.statusCode === 503 && error.message.includes("preview routing"),
    );
    assert.deepEqual(paths, ["/info", "/info"]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await fs.rm(path.dirname(client.socketPath), {
      recursive: true,
      force: true,
    });
    await f.clean();
  }
});

test(
  "HTTP resume uses the saved external folder, deduplicates across clients/reconnects, exits with Codex, and preserves retry identity",
  { timeout: 30000 },
  async () => {
    const f = await setup();
    const previousHome = process.env.SLOPZOOKA_HOME;
    const previousCodexHome = process.env.CODEX_HOME;
    const previousCommand = process.env.SLOPZOOKA_CODEX_COMMAND;
    const previousShell = process.env.SHELL;
    process.env.SLOPZOOKA_HOME = f.home;
    process.env.CODEX_HOME = f.home;
    process.env.SLOPZOOKA_CODEX_COMMAND = f.environment.SLOPZOOKA_CODEX_COMMAND;
    process.env.SHELL = "/bin/sh";
    const { WorkspaceService } = await import("../src/workspace.js");
    const sessions = await SessionServiceClient.forHome(f.home);
    const codex = new CodexThreads(
      f.diagnostics.logger("codex-threads"),
      f.environment,
    );
    const app = express();
    app.use(express.json());
    const hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const clients = [
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    ];
    installCodexThreadRoutes(
      app,
      codex,
      sessions,
      new WorkspaceService(f.diagnostics.logger("workspaces")),
      headsetCodexLaunch({
        home: f.home,
        hostId,
        origin: "http://127.0.0.1:7778",
        previewCommand: process.execPath,
        previewArgs: ["preview.mjs"],
        logger: f.diagnostics.logger("preview-routing"),
      }),
    );
    app.use(
      (
        error: Error,
        _req: express.Request,
        res: express.Response,
        _next: express.NextFunction,
      ) => {
        res
          .status(error instanceof ServiceError ? error.statusCode : 500)
          .json({ error: error.message });
      },
    );
    const server = http.createServer(app);
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const base = `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`;
    const resume = (id: string, sessionId: string) =>
      fetch(`${base}/api/codex/threads/${id}/resume`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-SlopZooka-Client-ID": clients[sessionId === "second" ? 1 : 0]!,
          Authorization: "Bearer fixture",
        },
        body: JSON.stringify({ sessionId, cwd: "/wrong", command: "false" }),
      });
    try {
      await sessions.connectOrStart();
      const response = await fetch(base + "/api/codex/threads");
      assert.equal(response.status, 200);
      const { threads } = (await response.json()) as {
        threads: { id: string }[];
      };
      const id = threads[1]!.id;
      const results = await Promise.all([
        resume(id, "first"),
        resume(id, "second"),
      ]);
      assert.ok(results.every((response) => response.status === 201));
      const [first, second] = await Promise.all(
        results.map((response) => response.json()),
      );
      assert.equal(first.session.id, second.session.id);
      assert.equal(
        first.session.cwd,
        await fs.realpath(path.join(f.home, "project")),
      );
      assert.match(first.session.workspaceId, /^codex-/);
      assert.equal(first.session.codexThreadId, id);
      assert.equal((await sessions.info()).sessions.length, 1);
      const peer = await SessionServiceClient.forHome(f.home);
      assert.equal((await peer.info()).sessions[0]!.id, first.session.id);
      assert.equal((await resume(threads[2]!.id, "missing")).status, 409);
      assert.equal((await resume("--last", "invalid")).status, 400);
      assert.equal((await resume(id, "")).status, 400);
      assert.equal((await sessions.info()).sessions.length, 1);
      let calls: any[] = [];
      const until = async (condition: () => Promise<boolean>) => {
        const deadline = Date.now() + 6000;
        while (!(await condition())) {
          assert.ok(Date.now() < deadline, "Condition timed out");
          await new Promise((resolve) => setTimeout(resolve, 25));
        }
      };
      await until(async () => {
        calls = await f.calls();
        return calls.some((call) => call.args?.includes("resume"));
      });
      const launches = calls.filter((call) => call.args?.includes("resume"));
      assert.equal(launches.length, 1);
      const args = launches[0].args as string[];
      assert.deepEqual(args.slice(-2), ["resume", id]);
      const [mcp, file, owner] = JSON.parse(
        args[3]!.split("args=")[1]!,
      ) as string[];
      assert.equal(mcp, "preview.mjs");
      assert.equal(owner, first.session.id);
      const route = await readPreviewConfig(file!);
      assert.equal(route.hostId, hostId);
      assert.equal(route.clientId, clients[owner === "second" ? 1 : 0]);
      assert.ok(!args.join(" ").includes("Bearer fixture"));
      assert.equal(launches[0].cwd, first.session.cwd);
      await sessions.paste(first.session.id, "exit", "x", true);
      await until(
        async () => (await sessions.info()).sessions[0]?.status === "exited",
      );
      // A lost reply for the second request must still resolve to the first launch,
      // even after the child has exited. A new operation may start a new terminal.
      const retried = await (await resume(id, "second")).json();
      assert.equal(retried.session.id, first.session.id);
      assert.equal(retried.session.status, "exited");
      const reopened = await (await resume(id, "third")).json();
      assert.notEqual(reopened.session.id, first.session.id);
      await fs.mkdir(path.join(f.home, "workspaces"));
      await fs.writeFile(
        path.join(f.home, "workspaces/index.json"),
        JSON.stringify([
          {
            workspaceId: "managed",
            repo: { name: "project", nameWithOwner: "test/project" },
            localCheckoutPath: first.session.cwd,
            worktreePath: first.session.cwd,
            profile: "codex",
            branchName: "existing",
            baseRef: "main",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
          },
        ]),
      );
      const managed = await (
        await resume(threads[3]!.id, "managed-thread")
      ).json();
      assert.equal(managed.session.workspaceId, "managed");
      assert.equal(
        managed.session.title,
        "Private thread 3",
        "Workspace naming cannot overwrite the Codex title",
      );
      assert.equal(managed.session.projectName, "project");
      assert.ok(managed.session.workspaceName);
      await sessions
        .create({
          id: "third",
          workspaceId: first.session.workspaceId,
          cwd: first.session.cwd,
          profile: "codex",
          environment: f.environment,
          codexResume: { threadId: threads[3]!.id, title: "Other" },
        })
        .then(
          () =>
            assert.fail(
              "Reusing an operation for another thread must conflict",
            ),
          (error: ServiceError) => assert.equal(error.statusCode, 409),
        );
    } finally {
      codex.stop();
      await sessions.stop().catch(() => {});
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await fs.rm(path.dirname(sessions.socketPath), {
        recursive: true,
        force: true,
      });
      for (const [key, value] of Object.entries({
        SLOPZOOKA_HOME: previousHome,
        CODEX_HOME: previousCodexHome,
        SLOPZOOKA_CODEX_COMMAND: previousCommand,
        SHELL: previousShell,
      })) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
      await f.clean();
    }
  },
);
