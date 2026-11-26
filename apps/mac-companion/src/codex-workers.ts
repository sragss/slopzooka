import { installedNativeCua } from "./installed-cua.js";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { CodexRPC, type NativeMessage } from "./codex-rpc.js";
import { ServiceError } from "./errors.js";
import type { Logger } from "./logger.js";
import type { SessionManager } from "./sessions.js";
import {
  codexPreviewOverrides,
  type SessionLaunch,
} from "./session-service-protocol.js";
import { stopProcessTree } from "./process-tree.js";

const MAX_COORDINATED_WORKERS = 20;
export const WORKER_CAPABILITY = "coordinator-workers-v1";
export type WorkerLaunch = {
  nativeControl?: boolean;
  session: SessionLaunch;
  clientId: string;
  executable: string;
  model?: string;
  task: string;
  previewConfig: string;
  previewCommand: string;
  previewArgs: string[];
};
export type WorkerSubmission = {
  requestId: string;
  text: string;
  mode: "queue" | "steer";
  expectedTurnId?: string;
};
export type Delivery = {
  requestId: string;
  status:
    | "queued"
    | "running"
    | "completed"
    | "failed"
    | "interrupted"
    | "uncertain";
  turnId?: string;
  queuedId?: string;
};
export type WorkerQuestion = {
  id: string;
  title: string;
  details: string;
  choices: string[];
};
export type WorkerState = {
  sessionId: string;
  workspaceId: string;
  threadId?: string;
  status: string;
  turnId?: string;
  result?: string;
  error?: string;
  question?: WorkerQuestion;
  deliveries: Delivery[];
};
type NativeTurn = {
  id: string;
  status: string;
  items: { type: string; clientId?: string; text?: string }[];
};
type NativeThread = {
  id: string;
  status: { type: string };
  turns?: NativeTurn[];
};
type QueueEntry = { id: string; clientUserMessageId: string };
type Worker = {
  launch: WorkerLaunch;
  fingerprint: string;
  state: WorkerState;
  child?: ChildProcess;
  rpc?: CodexRPC;
  socket: string;
  ready: Promise<void>;
  tail: Promise<unknown>;
  submissions: Map<string, { payload: string; delivery: Delivery }>;
  pendingQuestion?: NativeMessage;
  stopped: boolean;
};
const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
const input = (text: string) => [{ type: "text", text }];
const fingerprint = (value: unknown) =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex");

/** Owns only coordinated workers alongside SessionManager, never in the HTTP/model process. */
export class CodexWorkers {
  private workers = new Map<string, Worker>();
  constructor(
    private directory: string,
    private sessions: SessionManager,
    private logger: Logger,
    private nativeRuntime: typeof installedNativeCua = installedNativeCua,
  ) {}
  async start(launch: WorkerLaunch): Promise<WorkerState> {
    const id = launch.session.id;
    let worker = this.workers.get(id);
    const signature = fingerprint(launch);
    if (worker && worker.fingerprint !== signature)
      throw new ServiceError("Worker ID already used for another launch", 409);
    if (!worker) {
      if (this.workers.size >= MAX_COORDINATED_WORKERS)
        throw new ServiceError(
          `All ${MAX_COORDINATED_WORKERS} coordinated worker slots are in use on this Mac. End a session you no longer need, then retry in the existing worktree.`,
          409,
        );
      worker = {
        launch,
        fingerprint: signature,
        state: {
          sessionId: id,
          workspaceId: launch.session.workspaceId,
          status: "starting",
          deliveries: [],
        },
        socket: path.join(this.directory, `w-${randomUUID().slice(0, 8)}.sock`),
        ready: Promise.resolve(),
        tail: Promise.resolve(),
        submissions: new Map(),
        stopped: false,
      };
      this.workers.set(id, worker);
      worker.ready = this.boot(worker).catch(async (error: unknown) => {
        worker!.state.status = "failed";
        worker!.state.error =
          error instanceof ServiceError
            ? error.message
            : "Worker startup failed; inspect diagnostics before retrying.";
        this.logger.warn("worker.start.failed", { sessionId: id });
        if (!worker!.state.turnId && worker!.child?.pid) {
          worker!.rpc?.close();
          await stopProcessTree(worker!.child.pid, () => {
            worker!.child?.kill("SIGTERM");
          });
        }
        throw error;
      });
    }
    await worker.ready;
    return this.snapshot(worker);
  }
  private async boot(w: Worker) {
    const launch = w.launch;
    const nativeArgs = launch.nativeControl
      ? await this.nativeRuntime(
          launch.session.environment.HOME!,
          this.directory,
        )
      : [];
    const args = [
      ...nativeArgs,
      ...codexPreviewOverrides({
        command: launch.previewCommand,
        args: [...launch.previewArgs, launch.previewConfig],
      }),
      "app-server",
      "--listen",
      `unix://${w.socket}`,
    ];
    const env = { ...launch.session.environment };
    // The companion may have been started from iTerm. Its identity must not
    // misdirect a worker into controlling that unrelated native terminal.
    env.TERM_PROGRAM = "SlopZooka";
    delete env.TERM_PROGRAM_VERSION;
    delete env.TERM_SESSION_ID;
    delete env.ITERM_SESSION_ID;
    // Pi's model credentials never belong in a coding worker or its children.
    delete env.SLOPZOOKA_COORDINATOR_CONFIG;
    for (const key of Object.keys(env))
      if (key.startsWith("BROWSER_USE_ACCESS_") || key === "CODEX_THREAD_ID")
        delete env[key];
    const child = spawn(launch.executable, args, {
      cwd: launch.session.cwd,
      env,
      stdio: "ignore",
    });
    w.child = child;
    let failed = false;
    child.on("error", () => {
      failed = true;
      w.state.status = "failed";
      w.state.error = "Codex executable could not start";
    });
    child.on("exit", () => {
      failed = true;
      w.state.status = "unavailable";
      w.state.question = undefined;
      w.rpc?.close();
    });
    for (let i = 0; ; i++) {
      if (failed || w.stopped || i >= 100)
        throw new ServiceError("Codex startup unavailable", 503);
      if (
        await fs.access(w.socket).then(
          () => true,
          () => false,
        )
      )
        break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const rpc = new CodexRPC(w.socket, (message) => {
      if (w.rpc === rpc) this.receive(w, message);
    });
    w.rpc = rpc;
    await rpc.initialize();
    const start = await rpc.call<{ thread: NativeThread; model?: string }>(
      "thread/start",
      {
        cwd: launch.session.cwd,
        ...(launch.model ? { model: launch.model } : {}),
        developerInstructions:
          `SlopZooka worktree ID: ${JSON.stringify(launch.session.workspaceId)}. Terminal/session ID: ${JSON.stringify(launch.session.id)}. ` +
          "This is a SlopZooka coordinated worktree. Use repo and worktree in user-facing replies. Keep local repos on this Mac. Only add a remote, publish or push when the user explicitly asks. Your terminal is rendered inside SlopZooka on Apple Vision Pro, not iTerm or Terminal.app. SlopZooka window/worktree display names are owned by the coordinator's explicit tools. Do not try shell OSC title escapes or native Mac terminal control to rename them; report that the coordinator must perform that action. The user's request may include preparing apps and showing previews on their headset. Use the configured slopzooka-previews MCP only for explicitly requested headset previews. Use your existing tools for setup and app interaction. Do not claim a layout acknowledgement proves the user sees the content. Report missing tools, permissions, or offline headset honestly. Begin the final reply with a concise outcome paragraph including essential limitations; put supporting details after it. Do not spawn other coding agents for these coordination tasks." +
          (launch.nativeControl
            ? " Native computer control is provided by the slopzooka-native MCP. Follow its live guidance and finish each interaction with its completion summary to release shared Mac input. Other workers may code in parallel. After a busy response, reobserve the exact target before acting. Use native app control with an exact app path or bundle ID, not browser/tab APIs; this worker has no delegated browser-extension authority."
            : ""),
      },
    );
    if (!start.thread?.id)
      throw new ServiceError("Codex did not return a thread identity", 503);
    w.state.threadId = start.thread.id;
    // Qualify native queue support before admitting any user work.
    await rpc.call("thread/queue/list", { threadId: start.thread.id });
    if (w.stopped)
      throw new ServiceError("Worker launch stopped before submission", 409);
    // Codex persists a new thread only after its first real turn. This is the actual
    // task, never a hidden bootstrap prompt or a second reasoning session.
    const first = await rpc.call<{ turn: NativeTurn }>("turn/start", {
      threadId: start.thread.id,
      input: input(launch.task),
    });
    w.state.turnId = first.turn.id;
    w.state.status = "running";
    w.state.deliveries.push({
      requestId: launch.session.id,
      turnId: first.turn.id,
      status: "running",
    });
    // The TUI attaches to this exact backend/thread, with the same normal config.
    const command = [launch.executable, "--remote", `unix://${w.socket}`]
      .map(quote)
      .join(" ");
    this.sessions.create(
      launch.session.workspaceId,
      launch.session.cwd,
      "codex",
      launch.session.id,
      { ...env, SLOPZOOKA_CODEX_COMMAND: command },
      { threadId: start.thread.id, title: "Codex · coordinated" },
    );
    this.logger.info("worker.started", {
      sessionId: launch.session.id,
      threadId: start.thread.id,
      model: start.model,
    });
    if (w.stopped) await this.stop(launch.session.id);
  }
  private receive(w: Worker, message: NativeMessage) {
    if (message.method === "slopzooka/disconnected") {
      w.state.status = "unavailable";
      w.state.question = undefined;
      w.pendingQuestion = undefined;
      return;
    }
    const p = message.params ?? {};
    if (message.id !== undefined && message.method) {
      const schema = p.requestedSchema as
        | { required?: unknown[]; properties?: Record<string, unknown> }
        | undefined;
      const emptyForm =
        message.method === "mcpServer/elicitation/request" &&
        p.mode === "form" &&
        schema &&
        !schema.required?.length &&
        !Object.keys(schema.properties ?? {}).length;
      const supported =
        emptyForm ||
        [
          "item/commandExecution/requestApproval",
          "item/fileChange/requestApproval",
        ].includes(message.method);
      const details = JSON.stringify(p, null, 2);
      if (!supported || details.length > 16000) {
        w.rpc?.send({
          id: message.id,
          error: {
            code: -32601,
            message:
              "This request needs an unsupported approval/input UI. No permission granted. Stop and use a normal terminal session.",
          },
        });
        w.state.error =
          "Worker requested input not supported by the coordinator yet. No permission was granted.";
        return;
      }
      if (w.pendingQuestion) {
        w.rpc?.send({
          id: message.id,
          result: emptyForm
            ? { action: "decline", content: null, _meta: null }
            : { decision: "decline" },
        });
        return;
      }
      w.pendingQuestion = message;
      w.state.question = {
        id: String(message.id),
        title: "Codex needs your approval",
        details,
        choices: ["Allow once", "Decline"],
      };
      w.state.status = "waiting";
      return;
    }
    if (p.threadId !== w.state.threadId) return;
    if (message.method === "turn/started") {
      const turn = p.turn as NativeTurn;
      w.state.turnId = turn.id;
      w.state.status = "running";
      w.state.result = undefined;
    }
    if (message.method === "item/completed") {
      const item = p.item as NativeTurn["items"][number];
      if (item?.type === "agentMessage" && typeof item.text === "string")
        w.state.result = item.text.slice(0, 6000);
      if (item?.type === "userMessage" && item.clientId) {
        const delivery = w.submissions.get(item.clientId)?.delivery;
        if (delivery) {
          delivery.turnId = String(p.turnId);
          delivery.status = "running";
        }
      }
    }
    if (message.method === "turn/completed") {
      const turn = p.turn as NativeTurn;
      w.state.status = turn.status;
      w.state.turnId = undefined;
      for (const delivery of w.state.deliveries)
        if (delivery.turnId === turn.id)
          delivery.status =
            turn.status === "completed"
              ? "completed"
              : turn.status === "interrupted"
                ? "interrupted"
                : "failed";
      if (w.pendingQuestion) {
        w.pendingQuestion = undefined;
        w.state.question = undefined;
      }
    }
  }
  private get(id: string) {
    const w = this.workers.get(id);
    if (!w)
      throw new ServiceError(
        "This terminal has no coordinated worker binding",
        404,
      );
    return w;
  }
  private snapshot(w: Worker): WorkerState {
    return structuredClone({
      ...w.state,
      deliveries: w.state.deliveries.slice(-16),
    });
  }
  async list(clientId: string) {
    const owned = [...this.workers.values()].filter(
      (w) => w.launch.clientId === clientId,
    );
    await Promise.all(
      owned.map((w) =>
        this.serialize(w, async () => {
          if (
            w.rpc &&
            !w.rpc.connected &&
            w.child?.exitCode === null &&
            w.child.signalCode === null &&
            w.state.threadId
          ) {
            try {
              const rpc = new CodexRPC(w.socket, (message) => {
                if (w.rpc === rpc) this.receive(w, message);
              });
              w.rpc = rpc;
              await w.rpc.initialize();
              await w.rpc.call("thread/resume", { threadId: w.state.threadId });
              await this.reconcile(w);
            } catch {
              // A live socket is not a usable worker until resume/reconcile
              // succeeds. Retire it so the next status read can reconnect.
              w.rpc?.close();
              w.state.status = "unavailable";
            }
          }
        }),
      ),
    );
    return owned.map((w) => this.snapshot(w));
  }
  client(id: string) {
    return this.get(id).launch.clientId;
  }
  private serialize<T>(w: Worker, fn: () => Promise<T>): Promise<T> {
    const result = w.tail.then(fn);
    w.tail = result.catch(() => undefined);
    return result;
  }
  async submit(id: string, request: WorkerSubmission): Promise<WorkerState> {
    const w = this.get(id);
    await w.ready;
    return this.serialize(w, async () => {
      const payload = fingerprint(request);
      const existing = w.submissions.get(request.requestId);
      if (existing) {
        if (existing.payload !== payload)
          throw new ServiceError("Request ID reused with different input", 409);
        await this.reconcile(w);
        return this.snapshot(w);
      }
      if (w.submissions.size >= 128)
        throw new ServiceError(
          "Worker request limit reached; start another session",
          409,
        );
      const delivery: Delivery = {
        requestId: request.requestId,
        status: "uncertain",
      };
      w.submissions.set(request.requestId, { payload, delivery });
      w.state.deliveries.push(delivery);
      const rpc = w.rpc!;
      try {
        if (request.mode === "steer") {
          if (
            !request.expectedTurnId ||
            request.expectedTurnId !== w.state.turnId
          )
            throw new ServiceError(
              "Active turn changed; refresh before steering",
              409,
            );
          const receipt = await rpc.call<{ turnId: string }>("turn/steer", {
            threadId: w.state.threadId,
            expectedTurnId: request.expectedTurnId,
            clientUserMessageId: request.requestId,
            input: input(request.text),
          });
          delivery.turnId = receipt.turnId;
          if (delivery.status === "uncertain") delivery.status = "running";
        } else {
          const result = await rpc.call<{ queuedSubmission: QueueEntry }>(
            "thread/queue/add",
            {
              threadId: w.state.threadId,
              clientUserMessageId: request.requestId,
              input: input(request.text),
            },
          );
          delivery.queuedId = result.queuedSubmission.id;
          if (delivery.status === "uncertain") delivery.status = "queued";
          if (delivery.status === "queued" && !w.state.turnId) {
            try {
              await rpc.call("thread/queue/start", {
                threadId: w.state.threadId,
                queuedSubmissionId: delivery.queuedId,
              });
            } catch {
              await this.reconcile(w);
            }
          }
        }
      } catch (error) {
        if (error instanceof ServiceError && error.statusCode === 409)
          delivery.status = "failed";
        else await this.reconcile(w).catch(() => {});
        throw error;
      }
      return this.snapshot(w);
    });
  }
  private async reconcile(w: Worker) {
    const rpc = w.rpc!;
    const queue = await rpc.call<{ data: QueueEntry[] }>("thread/queue/list", {
      threadId: w.state.threadId,
    });
    const response = await rpc.call<{ thread: NativeThread }>("thread/read", {
      threadId: w.state.threadId,
      includeTurns: true,
    });
    const active = response.thread.turns?.find(
      (turn) => turn.status === "inProgress",
    );
    w.state.turnId = active?.id;
    const latest = response.thread.turns?.at(-1);
    // Thread status (active/idle) is not our turn status (running/completed).
    // Reconnection must project the same state as live turn notifications.
    w.state.status = w.pendingQuestion
      ? "waiting"
      : active
        ? "running"
        : (latest?.status ?? response.thread.status.type);
    // Match item/completed: the last agent message is the current reply.
    // Keep its opening outcome; supporting details remain in the terminal.
    const text = latest?.items
      .filter((item) => item.type === "agentMessage")
      .at(-1)?.text;
    w.state.result = text ? text.slice(0, 6000) : undefined;
    for (const delivery of w.state.deliveries) {
      const id = delivery.requestId;
      const queued = queue.data.find((q) => q.clientUserMessageId === id);
      if (queued) {
        delivery.status = "queued";
        delivery.queuedId = queued.id;
        continue;
      }
      const turn = response.thread.turns?.find(
        (t) =>
          t.id === delivery.turnId ||
          t.items.some((i) => i.type === "userMessage" && i.clientId === id),
      );
      if (turn) {
        delivery.turnId = turn.id;
        delivery.status =
          turn.status === "inProgress"
            ? "running"
            : turn.status === "completed"
              ? "completed"
              : turn.status === "interrupted"
                ? "interrupted"
                : "failed";
      }
      // Absence is not evidence that a timed-out mutation never arrived.
    }
  }
  async answer(id: string, questionId: string, accept: boolean) {
    const w = this.get(id);
    if (!w.pendingQuestion || String(w.pendingQuestion.id) !== questionId)
      throw new ServiceError("Approval is no longer pending", 409);
    w.rpc!.send({
      id: w.pendingQuestion.id,
      result:
        w.pendingQuestion.method === "mcpServer/elicitation/request"
          ? {
              action: accept ? "accept" : "decline",
              content: accept ? {} : null,
              _meta: null,
            }
          : { decision: accept ? "accept" : "decline" },
    });
    w.pendingQuestion = undefined;
    w.state.question = undefined;
    w.state.status = "running";
    return this.snapshot(w);
  }
  async stop(id: string, requestIds?: string[]) {
    const w = this.get(id);
    if (!requestIds) w.stopped = true;
    if (!w.rpc || !w.state.threadId) {
      if (requestIds)
        throw new ServiceError("Agent is unavailable for cancellation.", 409);
      return this.snapshot(w);
    }
    return this.serialize(w, async () => {
      const queue = await w.rpc!.call<{ data: QueueEntry[] }>(
        "thread/queue/list",
        { threadId: w.state.threadId },
      );
      for (const entry of queue.data)
        if (requestIds?.includes(entry.clientUserMessageId)) {
          await w.rpc!.call("thread/queue/delete", {
            threadId: w.state.threadId,
            queuedSubmissionId: entry.id,
          });
          const delivery = w.submissions.get(
            entry.clientUserMessageId,
          )?.delivery;
          if (delivery) delivery.status = "interrupted";
        }
      const turnId = w.state.turnId;
      const scoped =
        !requestIds ||
        (turnId &&
          w.state.deliveries.some(
            (d) => d.turnId === turnId && requestIds.includes(d.requestId),
          ));
      if (turnId && scoped)
        await w.rpc!.call("turn/interrupt", {
          threadId: w.state.threadId,
          turnId,
        });
      if (w.pendingQuestion && scoped)
        await this.answer(id, String(w.pendingQuestion.id), false);
      return this.snapshot(w);
    });
  }
  async end(id: string) {
    const w = this.workers.get(id);
    if (!w) return;
    w.stopped = true;
    w.rpc?.close();
    if (w.child?.pid)
      await stopProcessTree(w.child.pid, () => {
        w.child?.kill("SIGTERM");
      });
    await fs.rm(w.socket, { force: true });
    this.workers.delete(id);
  }
  async close() {
    await Promise.all([...this.workers.keys()].map((id) => this.end(id)));
  }
}
