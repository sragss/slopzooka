import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

import express from "express";
import pty, { type IPty } from "node-pty";
import { WebSocketServer, type WebSocket } from "ws";

import { GitHubClient } from "./github.js";
import { createLogger } from "./logger.js";
import { WorkspaceService, workspacePaths, type LaunchWorkspaceRequest } from "./workspace.js";
import {
  isClientMessage,
  type ClientMessage,
  type ClusterSnapshotMessage,
  type CreateSurfaceMessage,
  type ErrorMessage,
  type HelloAckMessage,
  type ServerMessage,
  type SurfaceClosedMessage,
  type SurfaceCreatedMessage,
  type SurfaceSummary,
  type SurfaceKind,
  type TerminalOutputMessage,
  type TuiProfile
} from "../../../packages/protocol/src/index.js";

const PORT = Number(process.env.SLOPZOOKA_PORT ?? "7777");
const HOST = process.env.SLOPZOOKA_HOST ?? "::";
const CONTROL_HOST = `${localHostName()}.local:${PORT}`;
const CONTROL_ORIGIN = `http://${CONTROL_HOST}`;
const DEFAULT_CWD = path.resolve(import.meta.dirname, "../../..");
const CLUSTER_ID = "local";
const TUI_COMMANDS = {
  codex: process.env.SLOPZOOKA_CODEX_COMMAND ?? "codex",
  claude: process.env.SLOPZOOKA_CLAUDE_COMMAND ?? "claude",
  opencode: process.env.SLOPZOOKA_OPENCODE_COMMAND ?? "opencode"
} as const;
const logger = createLogger("SlopZooka", "mac-companion.log");
const gitHubClient = new GitHubClient();
const workspaceService = new WorkspaceService(logger, CONTROL_ORIGIN);

const app = express();
app.use(express.json());
app.use(express.static(path.join(import.meta.dirname, "..", "public")));

app.get("/terminal", (_req, res) => {
  res.sendFile(path.join(import.meta.dirname, "..", "public", "terminal.html"));
});

app.get("/health", (_req, res) => {
  const paths = workspacePaths();
  res.json({
    ok: true,
    name: "slopzooka-mac-companion",
    version: "0.1.0",
    hostname: os.hostname(),
    localHostName: localHostName(),
    controlOrigin: CONTROL_ORIGIN,
    cwd: DEFAULT_CWD,
    logFilePath: logger.logFilePath,
    workspacePaths: paths
  });
});

app.get("/clusters", (_req, res) => {
  res.json({
    clusterId: CLUSTER_ID,
    surfaces: Array.from(surfaceManager.surfaceSummaries())
  });
});

app.get("/api/repos/recent", async (req, res) => {
  const limit = normalizeLimit(req.query.limit);

  try {
    const result = await gitHubClient.listRecentRepos(limit);
    res.json({
      viewerLogin: result.viewerLogin,
      repos: result.repos
    });
  } catch (error) {
    logger.error("Failed to load recent repositories", {
      error: error instanceof Error ? error.message : String(error)
    });
    res.status(500).json({
      error: error instanceof Error ? error.message : "Failed to load recent repositories."
    });
  }
});

app.get("/api/workspaces", async (req, res) => {
  const limit = normalizeLimit(req.query.limit);

  try {
    const workspaces = await workspaceService.listWorkspaces(limit);
    res.json({
      workspaces
    });
  } catch (error) {
    logger.error("Failed to load workspaces", {
      error: error instanceof Error ? error.message : String(error)
    });
    res.status(500).json({
      error: error instanceof Error ? error.message : "Failed to load workspaces."
    });
  }
});

app.post("/api/workspaces/launch", async (req, res) => {
  const body = req.body as Partial<LaunchWorkspaceRequest> | undefined;
  const nameWithOwner = body?.nameWithOwner?.trim();
  const profile = normalizeProfile(body?.profile);
  const baseRef = body?.baseRef?.trim() || undefined;

  if (!nameWithOwner) {
    res.status(400).json({
      error: "nameWithOwner is required."
    });
    return;
  }

  try {
    const repo = await gitHubClient.getRepo(nameWithOwner);
    const result = await workspaceService.launchWorkspace(
      {
        nameWithOwner,
        profile,
        baseRef
      },
      repo
    );

    res.status(201).json(result);
  } catch (error) {
    logger.error("Failed to launch workspace", {
      repo: nameWithOwner,
      profile: profile ?? "terminal",
      error: error instanceof Error ? error.message : String(error)
    });
    res.status(500).json({
      error: error instanceof Error ? error.message : "Failed to launch workspace."
    });
  }
});

app.post("/api/workspaces/:clusterId/reopen", async (req, res) => {
  const clusterId = req.params.clusterId?.trim();
  const body = req.body as Partial<{ profile: TuiProfile | null }> | undefined;
  const profile = normalizeProfile(body?.profile);

  if (!clusterId) {
    res.status(400).json({
      error: "clusterId is required."
    });
    return;
  }

  try {
    const result = await workspaceService.reopenWorkspace(clusterId, profile);
    res.status(200).json(result);
  } catch (error) {
    logger.error("Failed to reopen workspace", {
      clusterId,
      profile: profile ?? "terminal",
      error: error instanceof Error ? error.message : String(error)
    });
    res.status(500).json({
      error: error instanceof Error ? error.message : "Failed to reopen workspace."
    });
  }
});

const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });

server.on("upgrade", (request, socket, head) => {
  if (request.url !== "/ws") {
    socket.destroy();
    return;
  }

  wss.handleUpgrade(request, socket, head, (ws) => {
    wss.emit("connection", ws, request);
  });
});

wss.on("connection", (ws) => {
  const clientSurfaceIds = new Set<string>();
  logger.info("WebSocket connected", {
    activeSurfaceCount: Array.from(surfaceManager.surfaceSummaries()).length
  });
  send(
    ws,
    {
      type: "hello_ack",
      serverVersion: "0.1.0",
      hostname: os.hostname(),
      controlOrigin: CONTROL_ORIGIN
    } satisfies HelloAckMessage
  );

  send(
    ws,
    {
      type: "cluster_snapshot",
      clusterId: CLUSTER_ID,
      surfaces: []
    } satisfies ClusterSnapshotMessage
  );

  ws.on("message", (raw) => {
    const message = parseMessage(raw.toString());
    if (!message) {
      logger.warn("Ignoring invalid client message");
      sendError(ws, "Ignoring invalid client message.");
      return;
    }

    handleClientMessage(ws, message, clientSurfaceIds);
  });

  ws.on("close", () => {
    logger.info("WebSocket closed", {
      ownedSurfaceCount: clientSurfaceIds.size
    });
    for (const surfaceId of clientSurfaceIds) {
      surfaceManager.closeSurface(surfaceId, "socket_closed");
    }
  });
});

server.listen(
  {
    port: PORT,
    host: HOST,
    ipv6Only: false
  },
  () => {
  logger.info("Companion listening", {
    controlOrigin: CONTROL_ORIGIN,
    bindHost: HOST,
    defaultCwd: DEFAULT_CWD,
    logFilePath: logger.logFilePath,
    workspacePaths: workspacePaths()
  });
  }
);

type SurfaceState = {
  summary: SurfaceSummary;
  pty: IPty;
  socket: WebSocket;
};

class SurfaceManager {
  private readonly surfaces = new Map<string, SurfaceState>();

  createSurface(ws: WebSocket, message: CreateSurfaceMessage): SurfaceSummary {
    const summary = createSurfaceSummary(message);
    const term = spawnSurface(
      summary.kind,
      summary.profile,
      summary.cwd,
      summary.cols,
      summary.rows
    );

    const state: SurfaceState = {
      summary,
      pty: term,
      socket: ws
    };

    this.surfaces.set(summary.id, state);
    logger.info("Surface created", {
      clusterId: CLUSTER_ID,
      surfaceId: summary.id,
      kind: summary.kind,
      profile: summary.profile ?? null,
      cwd: summary.cwd,
      cols: summary.cols,
      rows: summary.rows
    });

    term.onData((data) => {
      send(ws, {
        type: "terminal_output",
        surfaceId: summary.id,
        data
      } satisfies TerminalOutputMessage);
    });

    term.onExit(({ exitCode, signal }) => {
      this.surfaces.delete(summary.id);
      logger.info("Surface process exited", {
        surfaceId: summary.id,
        exitCode,
        signal
      });
      send(ws, {
        type: "surface_closed",
        surfaceId: summary.id,
        exitCode,
        signal,
        reason: "process_exit"
      } satisfies SurfaceClosedMessage);
    });

    return summary;
  }

  writeInput(surfaceId: string, data: string): void {
    const surface = this.requireSurface(surfaceId);
    surface.pty.write(data);
  }

  resize(surfaceId: string, cols: number, rows: number): void {
    const surface = this.requireSurface(surfaceId);
    surface.summary.cols = cols;
    surface.summary.rows = rows;
    surface.pty.resize(cols, rows);
  }

  closeSurface(surfaceId: string, reason: SurfaceClosedMessage["reason"]): void {
    const surface = this.surfaces.get(surfaceId);
    if (!surface) {
      return;
    }

    this.surfaces.delete(surfaceId);
    surface.pty.kill();
    logger.info("Surface closed", {
      surfaceId,
      reason
    });

    send(surface.socket, {
      type: "surface_closed",
      surfaceId,
      exitCode: null,
      reason
    } satisfies SurfaceClosedMessage);
  }

  surfaceSummaries(): Iterable<SurfaceSummary> {
    return Array.from(this.surfaces.values(), (surface) => surface.summary);
  }

  private requireSurface(surfaceId: string): SurfaceState {
    const surface = this.surfaces.get(surfaceId);
    if (!surface) {
      throw new Error(`Unknown surface: ${surfaceId}`);
    }
    return surface;
  }
}

const surfaceManager = new SurfaceManager();

function handleClientMessage(
  ws: WebSocket,
  message: ClientMessage,
  clientSurfaceIds: Set<string>
): void {
  try {
    switch (message.type) {
      case "hello":
        logger.info("Client hello", {
          clientName: message.clientName ?? "unknown"
        });
        return;
      case "create_surface": {
        const summary = surfaceManager.createSurface(ws, message);
        clientSurfaceIds.add(summary.id);
        send(ws, {
          type: "surface_created",
          clusterId: CLUSTER_ID,
          surface: summary
        } satisfies SurfaceCreatedMessage);
        return;
      }
      case "terminal_input":
        surfaceManager.writeInput(message.surfaceId, message.data);
        return;
      case "terminal_resize":
        logger.info("Surface resized", {
          surfaceId: message.surfaceId,
          cols: message.cols,
          rows: message.rows
        });
        surfaceManager.resize(message.surfaceId, message.cols, message.rows);
        return;
      case "close_surface":
        surfaceManager.closeSurface(message.surfaceId, "client_closed");
        clientSurfaceIds.delete(message.surfaceId);
        return;
    }
  } catch (error) {
    logger.error("Client message handling failed", {
      messageType: message.type,
      error: error instanceof Error ? error.message : String(error)
    });
    sendError(ws, error instanceof Error ? error.message : String(error));
  }
}

function createSurfaceSummary(message: CreateSurfaceMessage): SurfaceSummary {
  const cwd = resolveCwd(message.cwd);
  return {
    id: crypto.randomUUID(),
    kind: message.kind,
    profile: message.kind === "tui" ? message.profile : undefined,
    title: surfaceTitle(message.kind, message.profile, cwd),
    cwd,
    cols: normalizeDimension(message.cols, 120),
    rows: normalizeDimension(message.rows, 36)
  };
}

function spawnSurface(
  kind: SurfaceKind,
  profile: SurfaceSummary["profile"],
  cwd: string,
  cols: number,
  rows: number
): IPty {
  const shell = process.env.SHELL ?? "/bin/zsh";
  const env = {
    ...process.env,
    TERM: "xterm-256color"
  };

  if (kind === "tui") {
    const command = resolveTuiCommand(profile);
    return pty.spawn(shell, ["-lc", command], {
      cwd,
      cols,
      rows,
      env,
      name: "xterm-color"
    });
  }

  return pty.spawn(shell, ["-l"], {
    cwd,
    cols,
    rows,
    env,
    name: "xterm-color"
  });
}

function surfaceTitle(kind: SurfaceKind, profile: CreateSurfaceMessage["profile"], cwd: string): string {
  if (kind === "tui") {
    return `${displayProfile(profile)}:${path.basename(cwd) || cwd}`;
  }

  return `${kind}:${path.basename(cwd) || cwd}`;
}

function displayProfile(profile: CreateSurfaceMessage["profile"]): string {
  switch (profile) {
    case "claude":
      return "claude";
    case "opencode":
      return "opencode";
    case "codex":
    case undefined:
      return "codex";
  }
}

function resolveTuiCommand(profile: CreateSurfaceMessage["profile"]): string {
  switch (profile) {
    case "claude":
      return TUI_COMMANDS.claude;
    case "opencode":
      return TUI_COMMANDS.opencode;
    case "codex":
    case undefined:
      return TUI_COMMANDS.codex;
  }
}

function parseMessage(raw: string): ClientMessage | null {
  try {
    const data = JSON.parse(raw) as unknown;
    return isClientMessage(data) ? data : null;
  } catch {
    return null;
  }
}

function resolveCwd(candidate?: string): string {
  if (!candidate) {
    return DEFAULT_CWD;
  }

  const resolved = path.resolve(candidate);
  try {
    if (fs.statSync(resolved).isDirectory()) {
      return resolved;
    }
  } catch {
    return DEFAULT_CWD;
  }

  return DEFAULT_CWD;
}

function normalizeDimension(value: number | undefined, fallback: number): number {
  if (typeof value !== "number" || Number.isNaN(value) || value < 10) {
    return fallback;
  }

  return Math.floor(value);
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

function normalizeProfile(value: unknown): TuiProfile | null {
  if (value === "codex" || value === "claude" || value === "opencode") {
    return value;
  }

  return null;
}

function localHostName(): string {
  return process.env.SLOPZOOKA_LOCAL_HOSTNAME ?? os.hostname().replace(/\.local$/, "");
}

function send(ws: WebSocket, message: ServerMessage): void {
  if (ws.readyState !== ws.OPEN) {
    return;
  }

  ws.send(JSON.stringify(message));
}

function sendError(ws: WebSocket, message: string): void {
  logger.error("Sending error to client", {
    errorMessage: message
  });
  send(ws, {
    type: "error",
    message
  } satisfies ErrorMessage);
}

process.on("uncaughtException", (error) => {
  logger.error("Uncaught exception", {
    error: error.message,
    stack: error.stack
  });
});

process.on("unhandledRejection", (reason) => {
  logger.error("Unhandled rejection", {
    reason: reason instanceof Error ? reason.message : String(reason)
  });
});
