import { installSurfaceProbe } from "./surface-probe.js";
import { ServiceError } from "./errors.js";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import http from "node:http";
import os from "node:os";
import path from "node:path";

import express from "express";
import { WebSocketServer, type WebSocket } from "ws";

import { SLOPZOOKA_BONJOUR_TYPE, startBonjourAdvertiser } from "./bonjour.js";
import { GitHubClient } from "./github.js";
import { createLogger } from "./logger.js";
import { FrontendService } from "./frontends.js";
import {
  WorkspaceService,
  workspacePaths,
  type LaunchWorkspaceRequest,
} from "./workspace.js";
import {
  PROTOCOL_VERSION,
  validId,
  validProfile,
  type TuiProfile,
} from "../../../packages/protocol/src/index.js";
import { SessionServiceClient } from "./session-service-client.js";
import type { ServiceInfo } from "./session-service-protocol.js";
import { Pairing } from "./auth.js";
import { loadDesktopPath } from "./desktop.js";
import { DashboardAddress } from "./dashboard-address.js";
import {
  installWindowLayoutRoutes,
  WindowLayoutStore,
} from "./window-layout.js";

await loadDesktopPath();

const PORT = Number(process.env.SLOPZOOKA_PORT ?? "7777");
const HOST = process.env.SLOPZOOKA_HOST ?? "::";
const LOCAL_HOST_NAME = localHostName();
const CONTROL_HOST = `${LOCAL_HOST_NAME}.local:${PORT}`;
const CONTROL_ORIGIN = `http://${CONTROL_HOST}`;
const BONJOUR_SERVICE_NAME = advertisedServiceName();
const DEFAULT_CWD = path.resolve(import.meta.dirname, "../../..");
const logger = createLogger("SlopZooka", "mac-companion.log");
const gitHubClient = new GitHubClient();
const workspaceService = new WorkspaceService(logger);

const sessionService = await SessionServiceClient.forHome(
  workspacePaths().slopzookaHome,
);
const companionInstanceId = randomUUID();
let sessionStatus: ServiceInfo | undefined;
let sessionServiceAvailable = false;
let admissionReady = false;
let changingService = false;
let serviceGeneration = 0;
const pairing: Pairing = new Pairing(
  workspacePaths().slopzookaHome,
  () => dashboardAddress.proxyOrigin,
);
const dashboardAddress = new DashboardAddress(PORT, pairing.hostId, logger);
const frontendService = new FrontendService(logger, {
  dashboardOrigin: () => dashboardAddress.proxyOrigin,
  workspaces: () => workspaceService.frontendWorkspaces(),
});
// Pairing codes are intentionally printed only to the local console, never the log file.
let displayedPairingCode = pairing.code;
console.log(`SlopZooka pairing code: ${displayedPairingCode}`);

let frontendCount = 0;
let pollingSessions = false;
const catalogTimer = setInterval(() => {
  if (pairing.code !== displayedPairingCode) {
    displayedPairingCode = pairing.code;
    console.log(`SlopZooka pairing code: ${displayedPairingCode}`);
  }
  void frontendService.getCatalog().then((catalog) => {
    frontendCount = catalog.frontends.filter(
      (frontend) =>
        frontend.status !== "stopped" && frontend.category !== "service",
    ).length;
  });
  if (changingService || pollingSessions) return;
  pollingSessions = true;
  const generation = serviceGeneration;
  void sessionService
    .info()
    .then((info) => {
      if (generation !== serviceGeneration) return;
      sessionStatus = info;
      sessionServiceAvailable = true;
    })
    .catch(() => {
      if (generation !== serviceGeneration) return;
      sessionServiceAvailable = false;
    })
    .finally(() => {
      pollingSessions = false;
      publishDesktopStatus();
    });
}, 2000);
catalogTimer.unref();

const app = express();
app.use(express.json({ limit: "128kb" }));
app.use((req, res, next) => {
  if (shuttingDown || !admissionReady) {
    res.status(503).json({
      error: shuttingDown
        ? "Companion is shutting down"
        : "Companion is starting",
    });
    return;
  }
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("X-Content-Type-Options", "nosniff");
  if (req.body?.profile !== undefined && !validProfile(req.body.profile)) {
    res.status(400).json({ error: "Unknown terminal profile" });
    return;
  }
  next();
});
pairing.install(app);
installWindowLayoutRoutes(
  app,
  new WindowLayoutStore(workspacePaths().slopzookaHome),
);
if (process.env.SLOPZOOKA_SURFACE_PROBE_MANIFEST)
  installSurfaceProbe(app, process.env.SLOPZOOKA_SURFACE_PROBE_MANIFEST);
const publicRoot = path.join(import.meta.dirname, "..", "public");
app.use(express.static(publicRoot));

app.get("/dashboard", async (_req, res) => {
  res.redirect(302, await dashboardAddress.destination());
});

app.get("/terminal", (_req, res) => {
  res.sendFile("terminal.html", { root: publicRoot });
});

app.get("/health", (_req, res) => {
  const paths = workspacePaths();
  res.json({
    ok: true,
    hostId: pairing.hostId,
    companionInstanceId,
    sessionServiceAvailable,
    runtime: import.meta.url.endsWith(".ts") ? "development" : "packaged",
    paired: pairing.authorized(_req),
    protocolVersion: PROTOCOL_VERSION,
    name: "slopzooka-mac-companion",
    version: "0.2.0",
    hostname: os.hostname(),
    localHostName: LOCAL_HOST_NAME,
    controlOrigin: CONTROL_ORIGIN,
    bonjourServiceType: `_${SLOPZOOKA_BONJOUR_TYPE}._tcp`,
    cwd: DEFAULT_CWD,
    logFilePath: logger.logFilePath,
    workspacePaths: paths,
  });
});

app.get("/api/sessions", async (_req, res) => {
  try {
    const info = await sessionService.info();
    res.json({
      sessions: await workspaceService.describeSessions(info.sessions),
      companionInstanceId,
      serviceInstanceId: info.instanceId,
      surfaceProbe: !!process.env.SLOPZOOKA_SURFACE_PROBE_MANIFEST,
    });
  } catch (error) {
    sendWorkspaceError(res, error, "Session service unavailable");
  }
});
app.post("/api/workspaces/:workspaceId/sessions", async (req, res) => {
  try {
    if (
      !validId(req.params.workspaceId) ||
      !validProfile(req.body?.profile ?? null) ||
      !validId(req.body?.sessionId)
    )
      throw new ServiceError(
        "Valid workspaceId, sessionId and profile required",
        400,
      );
    const workspace = await workspaceService.getWorkspace(
      req.params.workspaceId,
    );
    if (!workspace.existsOnDisk)
      throw new ServiceError("Workspace directory is missing", 409);
    const session = await sessionService.create({
      workspaceId: workspace.workspaceId,
      cwd: workspace.worktreePath,
      profile: req.body.profile ?? null,
      id: req.body.sessionId,
      environment: Object.fromEntries(
        Object.entries(process.env).filter(
          (entry): entry is [string, string] => entry[1] !== undefined,
        ),
      ),
    });
    const sessions = await workspaceService.describeSessions(
      (await sessionService.info()).sessions,
    );
    res.status(201).json({
      session: sessions.find((candidate) => candidate.id === session.id),
    });
  } catch (error) {
    sendWorkspaceError(res, error, "Could not create session");
  }
});
app.patch("/api/sessions/:sessionId", async (req, res) => {
  try {
    if (!validId(req.params.sessionId))
      throw new ServiceError("Valid sessionId required", 400);
    const session = await sessionService.rename(
      req.params.sessionId,
      req.body?.name,
    );
    const [described] = await workspaceService.describeSessions([session]);
    res.json({ session: described });
  } catch (error) {
    sendWorkspaceError(res, error, "Could not rename session");
  }
});
app.delete("/api/sessions/:sessionId", async (req, res) => {
  try {
    await sessionService.end(req.params.sessionId);
    res.json({ ok: true });
  } catch (error) {
    sendWorkspaceError(res, error, "Could not terminate session");
  }
});

app.get("/api/repos/recent", async (req, res) => {
  const limit = normalizeLimit(req.query.limit);

  try {
    const result = await gitHubClient.listRecentRepos(limit);
    res.json({
      viewerLogin: result.viewerLogin,
      repos: result.repos,
    });
  } catch (error) {
    logger.error("Failed to load recent repositories", {
      error: error instanceof Error ? error.message : String(error),
    });
    res.status(500).json({
      error:
        error instanceof Error
          ? error.message
          : "Failed to load recent repositories.",
    });
  }
});

app.get("/api/owners", async (_req, res) => {
  try {
    const result = await gitHubClient.listAvailableOwners();
    res.json(result);
  } catch (error) {
    logger.error("Failed to load available owners", {
      error: error instanceof Error ? error.message : String(error),
    });
    res.status(500).json({
      error:
        error instanceof Error
          ? error.message
          : "Failed to load available owners.",
    });
  }
});

app.get("/api/workspaces", async (req, res) => {
  const limit = normalizeLimit(req.query.limit);
  const includeArchived =
    req.query.includeArchived === "1" || req.query.includeArchived === "true";

  try {
    const workspaces = await workspaceService.listWorkspaces(
      limit,
      includeArchived,
    );
    res.json({
      workspaces,
    });
  } catch (error) {
    logger.error("Failed to load workspaces", {
      error: error instanceof Error ? error.message : String(error),
    });
    sendWorkspaceError(res, error, "Failed to load workspaces.");
  }
});

app.post("/api/workspaces/launch", async (req, res) => {
  const body = req.body as Partial<LaunchWorkspaceRequest> | undefined;
  const nameWithOwner =
    typeof body?.nameWithOwner === "string" ? body.nameWithOwner.trim() : "";
  const profile = normalizeProfile(body?.profile);
  const baseRef =
    typeof body?.baseRef === "string"
      ? body.baseRef.trim() || undefined
      : undefined;

  if (!nameWithOwner) {
    res.status(400).json({
      error: "nameWithOwner is required.",
    });
    return;
  }

  try {
    const repo = await gitHubClient.getRepo(nameWithOwner);
    const result = await workspaceService.launchWorkspace(
      {
        nameWithOwner,
        profile,
        baseRef,
      },
      repo,
    );

    res.status(201).json(result);
  } catch (error) {
    logger.error("Failed to launch workspace", {
      repo: nameWithOwner,
      profile: profile ?? "terminal",
      error: error instanceof Error ? error.message : String(error),
    });
    sendWorkspaceError(res, error, "Failed to launch workspace.");
  }
});

app.post("/api/repos/create-and-launch", async (req, res) => {
  const body = req.body as
    | Partial<{
        owner: string;
        repoName: string;
        visibility: "private" | "public";
        profile: TuiProfile | null;
      }>
    | undefined;

  const owner = typeof body?.owner === "string" ? body.owner.trim() : "";
  const repoName = normalizeRepoName(body?.repoName);
  const visibility = body?.visibility === "public" ? "public" : "private";
  const profile = normalizeProfile(body?.profile);

  if (!owner) {
    res.status(400).json({
      error: "owner is required.",
    });
    return;
  }

  if (!repoName) {
    res.status(400).json({
      error: "repoName is required.",
    });
    return;
  }

  try {
    const repo = await gitHubClient.createRepo({
      owner,
      repoName,
      visibility,
      addReadme: true,
    });
    const result = await workspaceService.launchWorkspace(
      {
        nameWithOwner: repo.nameWithOwner,
        profile,
      },
      repo,
    );

    res.status(201).json(result);
  } catch (error) {
    logger.error("Failed to create and launch repository", {
      owner,
      repoName,
      visibility,
      profile: profile ?? "terminal",
      error: error instanceof Error ? error.message : String(error),
    });
    sendWorkspaceError(res, error, "Failed to create and launch repository.");
  }
});

app.patch("/api/workspaces/:workspaceId", async (req, res) => {
  try {
    const workspace = await workspaceService.renameWorkspace(
      req.params.workspaceId,
      req.body?.name,
    );
    res.json({ workspace });
  } catch (error) {
    sendWorkspaceError(res, error, "Could not rename workspace");
  }
});

app.post("/api/workspaces/:workspaceId/reopen", async (req, res) => {
  const workspaceId = req.params.workspaceId?.trim();
  const body = req.body as Partial<{ profile: TuiProfile | null }> | undefined;
  const profile = normalizeProfile(body?.profile);

  if (!workspaceId) {
    res.status(400).json({
      error: "workspaceId is required.",
    });
    return;
  }

  try {
    const result = await workspaceService.reopenWorkspace(
      workspaceId,
      body?.profile === undefined ? undefined : profile,
    );
    res.status(200).json(result);
  } catch (error) {
    logger.error("Failed to reopen workspace", {
      workspaceId,
      profile: profile ?? "terminal",
      error: error instanceof Error ? error.message : String(error),
    });
    sendWorkspaceError(res, error, "Failed to reopen workspace.");
  }
});

app.post("/api/workspaces/:workspaceId/archive", async (req, res) => {
  const workspaceId = req.params.workspaceId?.trim();

  if (!workspaceId) {
    res.status(400).json({
      error: "workspaceId is required.",
    });
    return;
  }

  try {
    const workspace = await workspaceService.archiveWorkspace(workspaceId);
    res.status(200).json({
      workspace,
    });
  } catch (error) {
    logger.error("Failed to archive workspace", {
      workspaceId,
      error: error instanceof Error ? error.message : String(error),
    });
    sendWorkspaceError(res, error, "Failed to archive workspace.");
  }
});

app.post("/api/workspaces/prune-missing", async (_req, res) => {
  try {
    const result = await workspaceService.pruneMissingWorkspaces();
    res.status(200).json(result);
  } catch (error) {
    logger.error("Failed to prune missing workspaces", {
      error: error instanceof Error ? error.message : String(error),
    });
    sendWorkspaceError(res, error, "Failed to prune missing workspaces.");
  }
});

app.get("/api/frontends", async (_req, res) =>
  res.json(await frontendService.getCatalog()),
);
app.post("/api/frontends", async (req, res) => {
  try {
    if (typeof req.body?.url !== "string")
      throw new ServiceError("Frontend URL required", 400);
    res
      .status(201)
      .json({ frontend: await frontendService.addURL(req.body.url) });
  } catch (error) {
    sendWorkspaceError(res, error, "Could not save frontend URL");
  }
});
app.delete("/api/frontends/:id", async (req, res) => {
  try {
    await frontendService.removeURL(req.params.id);
    res.json({ ok: true });
  } catch (error) {
    sendWorkspaceError(res, error, "Could not remove frontend URL");
  }
});
app.post("/api/frontends/open", async (req, res) => {
  try {
    if (typeof req.body?.id !== "string")
      throw new ServiceError("Frontend id required", 400);
    const hostname = new URL(`http://${req.headers.host}`).hostname;
    res.json(await frontendService.openFrontend(req.body.id, hostname));
  } catch (error) {
    sendWorkspaceError(res, error, "Could not open frontend");
  }
});

app.post("/api/sessions/:sessionId/input", async (req, res) => {
  try {
    const { text, commandId, sendReturn } = req.body ?? {};
    if (
      !validId(commandId) ||
      typeof text !== "string" ||
      text.length === 0 ||
      text.length > 65536 ||
      typeof sendReturn !== "boolean"
    )
      throw new ServiceError(
        "Valid commandId, text and sendReturn required",
        400,
      );
    await sessionService.paste(
      req.params.sessionId,
      commandId,
      text,
      sendReturn,
    );
    res.json({ ok: true, commandId });
  } catch (error) {
    sendWorkspaceError(res, error, "Could not submit input");
  }
});

app.use(
  (
    error: Error & { status?: number },
    _req: express.Request,
    res: express.Response,
    _next: express.NextFunction,
  ) => {
    res.status(error.status ?? 500).json({
      error: error.status === 400 ? "Invalid JSON request" : error.message,
    });
  },
);
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true, maxPayload: 128 * 1024 });

server.on("upgrade", (request, socket, head) => {
  if (
    shuttingDown ||
    request.url !== "/ws" ||
    !pairing.sameOrigin(request) ||
    !pairing.authorized(request)
  ) {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }
  wss.handleUpgrade(request, socket, head, (ws) => wss.emit("connection", ws));
});
const alive = new Set<WebSocket>();
const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (!alive.delete(ws)) {
      ws.terminate();
      continue;
    }
    ws.ping();
  }
}, 15_000);
heartbeat.unref();
wss.on("connection", (ws) => {
  alive.add(ws);
  ws.on("pong", () => alive.add(ws));
  void sessionService
    .relay(ws, {
      type: "hello",
      version: PROTOCOL_VERSION,
      hostId: pairing.hostId,
    })
    .catch((error) => {
      logger.warn("Session relay unavailable", { error: String(error) });
      ws.close(1013, "Session service unavailable; retry from the Mac menu");
    });
  ws.on("error", (error) =>
    logger.warn("Socket error", { error: error.message }),
  );
  ws.on("close", () => {
    alive.delete(ws);
  });
});

server.listen(
  {
    port: PORT,
    host: HOST,
    ipv6Only: false,
  },
  async () => {
    try {
      sessionStatus = await sessionService.connectOrStart();
      sessionServiceAvailable = true;
    } catch (error) {
      logger.error("Session service startup failed", { error: String(error) });
      // Keep management and diagnostics available; an unavailable/incompatible
      // service is never reported as an empty session catalog.
      sessionServiceAvailable = false;
    }
    admissionReady = true;
    dashboardAddress.start();
    publishDesktopStatus();
    logger.info("Companion listening", {
      controlOrigin: CONTROL_ORIGIN,
      bindHost: HOST,
      defaultCwd: DEFAULT_CWD,
      logFilePath: logger.logFilePath,
      workspacePaths: workspacePaths(),
    });
    bonjourAdvertiser = startBonjourAdvertiser({
      logger,
      name: BONJOUR_SERVICE_NAME,
      port: PORT,
      hostId: pairing.hostId,
    });
  },
);

let bonjourAdvertiser: { stop: () => Promise<void> } | null = null;

function sendWorkspaceError(
  res: express.Response,
  error: unknown,
  fallbackMessage: string,
): void {
  if (error instanceof ServiceError) {
    res.status(error.statusCode).json({
      error: error.message,
    });
    return;
  }

  res.status(500).json({
    error: error instanceof Error ? error.message : fallbackMessage,
  });
}

function normalizeLimit(value: unknown): number {
  if (typeof value !== "string") {
    return 30;
  }

  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return 30;
  }

  return Math.max(1, Math.min(Math.floor(parsed), 100));
}

function normalizeRepoName(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[\s_]+/g, "-")
    .replace(/[^a-z0-9-]+/g, "")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  return normalized || null;
}

function normalizeProfile(value: unknown): TuiProfile | null {
  if (value === "codex" || value === "claude" || value === "opencode") {
    return value;
  }

  return null;
}

function localHostName(): string {
  if (process.env.SLOPZOOKA_LOCAL_HOSTNAME) {
    return process.env.SLOPZOOKA_LOCAL_HOSTNAME;
  }

  try {
    const output = execFileSync("scutil", ["--get", "LocalHostName"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (output) {
      return output;
    }
  } catch {
    // Fall through to os.hostname() below.
  }

  return os.hostname().replace(/\.local$/, "");
}

function advertisedServiceName(): string {
  if (process.env.SLOPZOOKA_BONJOUR_NAME) {
    return process.env.SLOPZOOKA_BONJOUR_NAME;
  }

  return `SlopZooka-${LOCAL_HOST_NAME}-${PORT}`;
}

process.on("uncaughtException", (error) => {
  logger.error("Fatal error", { error: error.message });
  void shutdown("fatal", 1);
});
process.on("unhandledRejection", (error) => {
  logger.error("Unhandled rejection", { error: String(error) });
  void shutdown("fatal", 1);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void shutdown(signal);
  });
}

let shuttingDown = false;

// Private parent/child pipe, never an unauthenticated HTTP endpoint or log file.
function publishDesktopStatus(): void {
  if (
    process.env.SLOPZOOKA_DESKTOP !== "1" ||
    !server.listening ||
    shuttingDown
  )
    return;
  console.log(
    "SLZ_DESKTOP " +
      JSON.stringify({
        code: pairing.code,
        pairingDisplayUntil: pairing.displayUntil,
        sessions:
          sessionStatus?.sessions.filter(
            (session) => session.status === "running",
          ).length ?? 0,
        sessionServiceAvailable,
        sessionSocketPath: sessionService.socketPath,
        sessionLogPath: sessionService.logPath,
        viewers: wss.clients.size,
        frontends: frontendCount,
      }),
  );
}
if (process.env.SLOPZOOKA_DESKTOP === "1") {
  // An app crash closes this pipe too: do not orphan a hidden companion.
  let desktopInput = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk: string) => {
    desktopInput += chunk;
    if (desktopInput.length > 16 * 1024) {
      desktopInput = "";
      return;
    }
    let newline: number;
    while ((newline = desktopInput.indexOf("\n")) !== -1) {
      const line = desktopInput.slice(0, newline);
      desktopInput = desktopInput.slice(newline + 1);
      try {
        const command = JSON.parse(line);
        if (!validId(command.requestId)) continue;
        if (
          command.type === "restart-session-service" ||
          command.type === "stop-session-service"
        ) {
          if (changingService) {
            console.log(
              "SLZ_SERVICE " +
                JSON.stringify({
                  requestId: command.requestId,
                  error: "A session service operation is already in progress",
                }),
            );
            continue;
          }
          changingService = true;
          serviceGeneration++;
          void (async () => {
            try {
              try {
                await sessionService.stop();
              } catch (error) {
                if (
                  !["ENOENT", "ECONNREFUSED"].includes(
                    (error as NodeJS.ErrnoException).code ?? "",
                  )
                )
                  throw error;
              }
              sessionServiceAvailable = false;
              sessionStatus = undefined;
              if (command.type === "restart-session-service") {
                sessionStatus = await sessionService.connectOrStart();
                sessionServiceAvailable = true;
              }
              console.log(
                "SLZ_SERVICE " +
                  JSON.stringify({ requestId: command.requestId }),
              );
            } catch (error) {
              console.log(
                "SLZ_SERVICE " +
                  JSON.stringify({
                    requestId: command.requestId,
                    error: String(error),
                  }),
              );
            }
            changingService = false;
            publishDesktopStatus();
          })();
          continue;
        }
        if (command.type !== "open-dashboard") continue;
        void dashboardAddress.destination().then((destination) => {
          if (shuttingDown) return;
          console.log(
            "SLZ_DASHBOARD " +
              JSON.stringify({
                requestId: command.requestId,
                url: pairing.dashboardLink(destination),
              }),
          );
        });
      } catch {
        // Ignore malformed private commands; never print their contents.
      }
    }
  });
  process.stdin.resume();
  process.stdin.once("end", () => {
    void shutdown("desktop-disconnected");
  });
}

async function shutdown(signal: string, exitCode = 0): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info("Shutdown requested", { signal });
  const deadline = setTimeout(() => process.exit(exitCode || 1), 3000);
  deadline.unref();
  clearInterval(heartbeat);
  clearInterval(catalogTimer);
  for (const ws of wss.clients) ws.terminate();
  // Stop admission immediately, then wait for owned processes and upgraded sockets.
  const httpClosed = new Promise<void>((resolve) =>
    server.close(() => resolve()),
  );
  await Promise.allSettled([
    frontendService.stop(),
    dashboardAddress.stop(),
    bonjourAdvertiser?.stop(),
  ]);
  server.closeAllConnections();
  await httpClosed;
  process.exit(exitCode);
}
