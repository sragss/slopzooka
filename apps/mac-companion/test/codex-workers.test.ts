import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { CodexWorkers, type WorkerLaunch } from "../src/codex-workers.js";
import { SessionManager } from "../src/sessions.js";
const log = { info() {}, warn() {}, error() {} };
const client = "11111111-1111-4111-8111-111111111111";
const until = async (run: () => Promise<boolean>) => {
  for (let i = 0; i < 100; i++) {
    if (await run()) return;
    await new Promise((r) => setTimeout(r, 30));
  }
  throw new Error("Condition timed out");
};
test(
  "owned workers bind one terminal, deduplicate delivery, recover uncertain replies, scope Stop, and preserve approvals",
  { timeout: 30000 },
  async () => {
    const home = await fs.mkdtemp("/tmp/slz-worker-test-");
    const manager = new SessionManager(log);
    const workers = new CodexWorkers(home, manager, log, async () => []);
    const sessionId = randomUUID();
    const launch: WorkerLaunch = {
      nativeControl: true,
      session: {
        id: sessionId,
        workspaceId: "fixture",
        cwd: home,
        profile: "codex",
        environment: {
          HOME: process.env.HOME!,
          PATH: process.env.PATH!,
          SHELL: "/bin/sh",
          TERM_PROGRAM: "iTerm.app",
          ITERM_SESSION_ID: "unrelated-parent",
          TERM_SESSION_ID: "unrelated-parent",
        },
      },
      clientId: client,
      executable: path.resolve(
        import.meta.dirname,
        "fixtures/codex-worker.mjs",
      ),
      task: "hold initial",
      previewConfig: home + "/unused.json",
      previewCommand: process.execPath,
      previewArgs: [],
    };
    const rows = async () =>
      (await fs.readFile(home + "/effects.jsonl", "utf8"))
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
    try {
      const [a, b] = await Promise.all([
        workers.start(launch),
        workers.start(launch),
      ]);
      assert.equal(a.threadId, b.threadId);
      const environment = (await rows()).find((x) => x.event === "environment");
      assert.equal(environment.terminalProgram, "SlopZooka");
      assert.equal(environment.inheritedTerminalIdentity, false);
      assert.equal(manager.summaries().length, 1);
      assert.equal(manager.summaries()[0]!.codexThreadId, a.threadId);
      assert.equal((await rows()).filter((x) => x.event === "start").length, 1);
      assert.deepEqual(await workers.list(randomUUID()), []);
      await assert.rejects(
        workers.start({
          ...launch,
          clientId: randomUUID(),
          session: { ...launch.session, id: randomUUID() },
        }),
        /One native-control worker/,
      );
      await assert.rejects(
        workers.start({ ...launch, task: "another task" }),
        /another launch/,
      );
      const queued = {
        requestId: "queued-1",
        text: "queued",
        mode: "queue" as const,
      };
      await workers.submit(sessionId, queued);
      await workers.submit(sessionId, queued);
      assert.equal((await rows()).filter((x) => x.event === "queue").length, 1);
      await assert.rejects(
        workers.submit(sessionId, { ...queued, text: "different" }),
        /different input/,
      );
      await assert.rejects(
        workers.submit(sessionId, {
          requestId: "stale",
          text: "steer",
          mode: "steer",
          expectedTurnId: "wrong",
        }),
        /changed/,
      );
      await workers.submit(sessionId, {
        requestId: "steer",
        text: "steer",
        mode: "steer",
        expectedTurnId: a.turnId,
      });
      await assert.rejects(
        workers.submit(sessionId, {
          requestId: "lost",
          text: "lose-reply",
          mode: "queue",
        }),
        /uncertain|disconnected/,
      );
      await workers.list(client); // reconnect and reconcile, never resubmit
      await workers.submit(sessionId, {
        requestId: "lost",
        text: "lose-reply",
        mode: "queue",
      });
      assert.equal(
        (await rows()).filter(
          (x) => x.event === "queue" && x.request === "lost",
        ).length,
        1,
      );
      await workers.stop(sessionId, [sessionId, "lost"]);
      const stopped = (await workers.list(client))[0]!;
      assert.equal(
        stopped.deliveries.find((d) => d.requestId === "queued-1")?.status,
        "queued",
      );
      assert.equal(manager.summaries()[0]!.status, "running");
      // Queue belongs to Codex and Stop did not clear an unrelated follow-up.
      await workers.submit(sessionId, {
        requestId: "approval",
        text: "approval",
        mode: "queue",
      });
      await until(async () =>
        Boolean((await workers.list(client))[0]?.question),
      );
      const question = (await workers.list(client))[0]!.question!;
      assert.equal(
        (await rows()).filter((x) => x.event === "approval").length,
        0,
      );
      await workers.answer(sessionId, question.id, false);
      assert.equal(
        (await rows()).filter(
          (x) => x.event === "approval" && x.decision === "accept",
        ).length,
        0,
      );
      await assert.rejects(
        workers.answer(sessionId, question.id, true),
        /no longer/,
      );
    } finally {
      await workers.close();
      await manager.stop();
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);
