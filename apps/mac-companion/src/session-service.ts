import { logError } from "../../../packages/protocol/src/diagnostics.js";
import fs from "node:fs/promises";
import path from "node:path";
import http from "node:http";
import net from "node:net";
import { monitorEventLoopDelay } from "node:perf_hooks";
import { randomUUID } from "node:crypto";
import express from "express";
import { WebSocketServer } from "ws";
import { SessionManager, send } from "./sessions.js";
import { ServiceError } from "./errors.js";
import { createDiagnostics, logContext } from "./logger.js";
import { validLogId } from "../../../packages/protocol/src/diagnostics.js";
import {
  isClientMessage,
  validId,
  validProfile,
} from "../../../packages/protocol/src/index.js";
import {
  SESSION_SERVICE_VERSION,
  CODEX_RESUME_CAPABILITY,
  validCodexThreadId,
  type ServiceInfo,
} from "./session-service-protocol.js";

const instanceId = randomUUID();
const diagnostics = createDiagnostics("session-service", {
  directory: process.env.SLOPZOOKA_DIAGNOSTICS_DIR,
  runtimeId: process.argv[3],
  instanceId,
});
const logger = diagnostics.logger("session-service");

// Launched only under lockf: the OS releases the lock when this process exits.
async function main() {
  const [socketPath, runtimeId] = process.argv.slice(2);
  if (!socketPath || !runtimeId)
    throw new Error(
      "Session service requires a private socket and runtime identity",
    );
  process.umask(0o077);
  // Holding the lifetime lock permits stale-socket recovery, but never unlink a live listener.
  const live = await new Promise<boolean>((resolve, reject) => {
    const socket = net.connect(socketPath);
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", (error: NodeJS.ErrnoException) => {
      if (["ENOENT", "ECONNREFUSED"].includes(error.code ?? "")) resolve(false);
      else reject(error);
    });
  });
  if (live) process.exit(0);
  await fs.rm(socketPath, { force: true });
  // Only the lifetime-lock holder can prune old, inactive runtimes. Never
  // remove the executable/helpers of a running service during app replacement.
  const runtimeDirectory = path.dirname(process.execPath);
  const runtimeRoot = path.dirname(runtimeDirectory);
  if (
    path.basename(runtimeRoot) === "session-runtimes" &&
    path.basename(runtimeDirectory) === runtimeId
  ) {
    for (const name of await fs.readdir(runtimeRoot)) {
      if (/^[a-f0-9]{64}$/.test(name) && name !== runtimeId)
        await fs.rm(path.join(runtimeRoot, name), {
          recursive: true,
          force: true,
        });
    }
  }
  const manager = new SessionManager(diagnostics.logger("sessions"));
  const eventLoop = monitorEventLoopDelay({ resolution: 20 });
  eventLoop.enable();
  const diagnosticsTimer = setInterval(() => {
    manager.recordDiagnostics();
    if (manager.summaries().some((session) => session.status === "running"))
      logger.info("event-loop.summary", {
        delayMaxMs: Math.round(eventLoop.max / 1e6),
        delayMeanMs: Math.round(eventLoop.mean / 1e6),
      });
    eventLoop.reset();
  }, 10_000);
  diagnosticsTimer.unref();
  let stopping = false;
  const app = express();
  app.use((req, _res, next) => {
    const actionId = req.header("X-SlopZooka-Action-ID");
    logContext.run(validLogId(actionId) ? { actionId } : {}, next);
  });
  app.use(express.json({ limit: "256kb" }));
  app.use((_req, res, next) => {
    if (stopping) {
      res.status(503).json({ error: "Session service is stopping" });
      return;
    }
    next();
  });
  app.get("/info", (_req, res) =>
    res.json({
      version: SESSION_SERVICE_VERSION,
      instanceId,
      runtimeId,
      pid: process.pid,
      sessions: manager.summaries(),
      capabilities: [
        "rename-session",
        "diagnostics-v1",
        CODEX_RESUME_CAPABILITY,
      ],
      logFilePath: diagnostics.store.file,
    } satisfies ServiceInfo),
  );
  app.post("/diagnostics/flush", async (_req, res) =>
    res.json({ ok: await diagnostics.store.flush() }),
  );
  app.post("/sessions", (req, res) => {
    const { workspaceId, cwd, profile, id, environment, codexResume } =
      req.body ?? {};
    if (
      !validId(workspaceId) ||
      !validId(id) ||
      !validProfile(profile) ||
      typeof cwd !== "string" ||
      !path.isAbsolute(cwd) ||
      !environment ||
      typeof environment !== "object" ||
      Array.isArray(environment) ||
      Object.values(environment).some((value) => typeof value !== "string") ||
      (codexResume !== undefined &&
        (profile !== "codex" ||
          !validCodexThreadId(codexResume?.threadId) ||
          typeof codexResume?.title !== "string" ||
          !codexResume.title.length ||
          codexResume.title.length > 160 ||
          /\p{Cc}/u.test(codexResume.title)))
    )
      throw new ServiceError("Invalid session launch", 400);
    res.json(
      manager.create(workspaceId, cwd, profile, id, environment, codexResume),
    );
  });
  app.delete("/sessions/:id", (req, res) => {
    // Repeating an end after a lost reply must not end a different session.
    if (manager.summaries().some((session) => session.id === req.params.id))
      manager.terminate(req.params.id);
    res.json({ ok: true });
  });
  app.patch("/sessions/:id", (req, res) => {
    res.json(manager.rename(req.params.id, req.body?.name));
  });
  app.post("/sessions/:id/input", (req, res) => {
    const { commandId, text, sendReturn } = req.body ?? {};
    if (
      !validId(commandId) ||
      typeof text !== "string" ||
      !text.length ||
      text.length > 65536 ||
      typeof sendReturn !== "boolean"
    )
      throw new ServiceError("Invalid input", 400);
    manager.paste(req.params.id, commandId, text, sendReturn);
    res.json({ ok: true });
  });
  app.post("/stop", (_req, res) => {
    res.json({ ok: true });
    void stop();
  });
  app.use(
    (
      error: Error & { status?: number },
      _req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      logger.warn("service.request.failed", { error: logError(error) });
      res
        .status(
          error instanceof ServiceError
            ? error.statusCode
            : (error.status ?? 500),
        )
        .json({ error: error.message });
    },
  );
  const server = http.createServer(app);
  const wss = new WebSocketServer({
    server,
    path: "/terminal",
    maxPayload: 128 * 1024,
  });
  wss.on("connection", (ws, request) => {
    const supplied = request.headers["x-slopzooka-connection-id"];
    const connectionId = validLogId(supplied) ? supplied : randomUUID();
    const log = diagnostics.logger("terminal-transport", { connectionId });
    log.info("connection.opened");
    if (stopping) {
      ws.close(1012);
      return;
    }
    ws.send(
      JSON.stringify({
        type: "service-ready",
        version: SESSION_SERVICE_VERSION,
        instanceId,
        supportsTakeControl: true,
        supportsInputAck: true,
        sessions: manager.summaries(),
      }),
    );
    ws.on("error", (error) => log.warn("connection.failed", { error }));
    ws.on("message", (raw) => {
      try {
        const message: unknown = JSON.parse(raw.toString());
        if (!isClientMessage(message))
          throw new ServiceError("Invalid protocol message", 400);
        logContext.run({ connectionId }, () => {
          switch (message.type) {
            case "hello":
              break;
            case "attach":
              manager.attach(ws, message.sessionId, message.cursor);
              break;
            case "detach":
              manager.detach(ws, message.sessionId);
              break;
            case "take-control":
              manager.takeControl(ws, message.sessionId);
              break;
            case "input":
              manager.input(ws, message.sessionId, message.data);
              if (message.probeId !== undefined)
                send(ws, {
                  type: "input-ack",
                  sessionId: message.sessionId,
                  probeId: message.probeId,
                });
              break;
            case "resize":
              manager.resize(ws, message.sessionId, message.cols, message.rows);
              break;
            case "ack":
              manager.acknowledge(ws, message.sessionId, message.cursor);
              break;
          }
        });
      } catch (error) {
        log.warn("message.rejected", { error: logError(error) });
        send(ws, {
          type: "error",
          message: error instanceof Error ? error.message : "Invalid request",
          code:
            error instanceof ServiceError ? String(error.statusCode) : "400",
        });
      }
    });
    ws.on("close", () => {
      log.info("connection.closed");
      logContext.run({ connectionId }, () => manager.detach(ws));
    });
  });
  async function stop() {
    if (stopping) return;
    stopping = true;
    clearInterval(diagnosticsTimer);
    eventLoop.disable();
    manager.recordDiagnostics();
    logger.info("service.stopping");
    const deadline = setTimeout(() => process.exit(1), 3000);
    deadline.unref();
    for (const ws of wss.clients) ws.terminate();
    await manager.stop();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await diagnostics.store.flush();
    process.exit(0);
  }
  for (const signal of ["SIGINT", "SIGTERM"] as const)
    process.on(signal, () => void stop());
  process.on("uncaughtException", (error) => {
    logger.error("process.uncaught-exception", { error: logError(error) });
    void stop();
  });
  process.on("unhandledRejection", (error) => {
    logger.error("process.unhandled-rejection", { error: logError(error) });
    void stop();
  });
  logger.info("service.started", { instanceId, runtimeId, pid: process.pid });
  server.listen(socketPath);
  void diagnostics.store.flush();
}
void main().catch(async (error) => {
  logger.error("service.start.failed", { error: logError(error) });
  const deadline = setTimeout(() => process.exit(1), 1000);
  deadline.unref();
  await diagnostics.store.flush();
  process.exit(1);
});
