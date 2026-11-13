import crypto from "node:crypto";
import { stopProcessTree } from "./process-tree.js";
import pty, { type IPty } from "node-pty";
import headless from "@xterm/headless";
import serialize from "@xterm/addon-serialize";
import type { WebSocket } from "ws";
import type {
  SessionSummary,
  ServerMessage,
  TuiProfile,
} from "../../../packages/protocol/src/index.js";
import { ServiceError } from "./errors.js";
import { normalizedName } from "./names.js";
import type { Logger } from "./logger.js";
import { observeTerminalNotifications } from "./terminal-notifications.js";

const REPLAY_LIMIT = 512 * 1024;
const WINDOW = 128 * 1024;
// Byte limits alone allow hundreds of thousands of one-byte frames. Bound
// metadata and per-ACK work too, independently of PTY lifetime and other viewers.
const REPLAY_FRAMES = 4096;
const WINDOW_FRAMES = 256;
type Frame = {
  cursor: number;
  data: string;
  bytes: number;
  notificationSequence: number;
};
type Attachment = {
  sent: number;
  ack: number;
  bytes: number;
  frames: Array<{ cursor: number; bytes: number }>;
};
type Session = {
  summary: SessionSummary;
  pty: IPty;
  screen: InstanceType<typeof headless.Terminal>;
  serialize: InstanceType<typeof serialize.SerializeAddon>;
  cursor: number;
  notificationSequence: number;
  replay: Frame[];
  replayBytes: number;
  clients: Map<WebSocket, Attachment>;
  writer?: WebSocket;
  pendingBytes: number;
  commands: Map<string, string>;
  paused: boolean;
  inputBytes: number;
  outputBytes: number;
  pauses: number;
  parserMaxMs: number;
  pendingSince?: number;
  pauseStarted?: number;
  pauseMaxMs: number;
  outputFrames: number;
  checkpointMaxMs: number;
  checkpoints: number;
  ending: boolean;
};
export function send(ws: WebSocket, message: ServerMessage): void {
  if (ws.readyState !== ws.OPEN) return;
  if (ws.bufferedAmount > 2 * 1024 * 1024) {
    ws.close(1013, "Slow reader; reconnect to resume");
    return;
  }
  ws.send(JSON.stringify(message));
}

/** Owns processes independently of viewers. Lives in the session service; survives companion/viewer disconnects. */
export class SessionManager {
  private readonly sessions = new Map<string, Session>();
  private readonly terminations = new Set<Promise<void>>();
  private stopping = false;
  constructor(private readonly logger?: Logger) {}
  summaries(): SessionSummary[] {
    return [...this.sessions.values()].map((s) => ({ ...s.summary }));
  }
  rename(id: string, name: unknown): SessionSummary {
    const session = this.require(id);
    this.logger?.info("session.renamed", {
      sessionId: id,
      reset: name === null,
    });
    if (name === null) {
      delete session.summary.name;
    } else {
      session.summary.name = normalizedName(name);
    }
    return { ...session.summary };
  }
  create(
    workspaceId: string,
    cwd: string,
    profile: TuiProfile | null,
    id: string = crypto.randomUUID(),
    environment: NodeJS.ProcessEnv = process.env,
  ): SessionSummary {
    if (this.stopping)
      throw new ServiceError("Companion is shutting down", 503);
    const existing = this.sessions.get(id);
    if (existing) {
      if (
        existing.summary.workspaceId !== workspaceId ||
        existing.summary.profile !== profile ||
        existing.summary.cwd !== cwd
      )
        throw new ServiceError(
          "Session ID already used for a different launch",
          409,
        );
      this.logger?.info("session.create.reused", {
        sessionId: id,
        workspaceId,
      });
      return existing.summary;
    }
    if (this.sessions.size >= 100)
      throw new ServiceError(
        "Session limit reached; remove ended sessions",
        409,
      );
    const summary: SessionSummary = {
      id,
      workspaceId,
      profile,
      title: profile ?? "Terminal",
      cwd,
      cols: 120,
      rows: 36,
      status: "running",
      exitCode: null,
    };
    const commands = {
      codex: environment.SLOPZOOKA_CODEX_COMMAND ?? "codex",
      claude: environment.SLOPZOOKA_CLAUDE_COMMAND ?? "claude",
      opencode: environment.SLOPZOOKA_OPENCODE_COMMAND ?? "opencode",
    };
    const shell = environment.SHELL ?? "/bin/zsh";
    const terminalEnvironment: NodeJS.ProcessEnv = {
      ...environment,
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
    };
    // Launcher/automation output preferences must not disable this full-color PTY.
    // Users can still configure their terminal preferences in shell startup files.
    delete terminalEnvironment.NO_COLOR;
    // Keep a shell after the agent exits (including updater exits and launch failures).
    // Interactive login configuration matches a normal terminal (including .zshrc PATH/tool managers).
    // That shell owns job control, so it reclaims the foreground PTY when the agent subshell exits.
    // Pass commands as arguments so overrides cannot escape the lifecycle wrapper.
    const term = pty.spawn(
      shell,
      profile
        ? ["-lic", '(eval "$1"); exec "$0" -l', shell, commands[profile]]
        : ["-l"],
      {
        cwd,
        cols: summary.cols,
        rows: summary.rows,
        name: "xterm-256color",
        env: terminalEnvironment,
      },
    );
    const screen = new headless.Terminal({
      cols: summary.cols,
      rows: summary.rows,
      scrollback: 1000,
      allowProposedApi: true,
    });
    const serializer = new serialize.SerializeAddon();
    screen.loadAddon(serializer);
    const s: Session = {
      summary,
      pty: term,
      screen,
      serialize: serializer,
      cursor: 0,
      notificationSequence: 0,
      replay: [],
      replayBytes: 0,
      clients: new Map(),
      pendingBytes: 0,
      commands: new Map(),
      paused: false,
      inputBytes: 0,
      outputBytes: 0,
      pauses: 0,
      parserMaxMs: 0,
      pauseMaxMs: 0,
      outputFrames: 0,
      checkpointMaxMs: 0,
      checkpoints: 0,
      ending: false,
    };
    observeTerminalNotifications(screen, () => {
      s.notificationSequence += 1;
    });
    this.sessions.set(id, s);
    this.logger?.info("session.created", {
      sessionId: id,
      workspaceId,
      profile,
      pid: term.pid,
    });
    term.onData((data) => {
      const bytes = Buffer.byteLength(data);
      const started = performance.now();
      s.pendingSince ??= started;
      s.outputBytes += bytes;
      s.outputFrames++;
      s.pendingBytes += bytes;
      this.flow(s);
      screen.write(data, () => {
        s.pendingBytes -= bytes;
        s.parserMaxMs = Math.max(s.parserMaxMs, performance.now() - started);
        if (!s.pendingBytes) s.pendingSince = undefined;
        const frame = {
          cursor: ++s.cursor,
          data,
          bytes,
          notificationSequence: s.notificationSequence,
        };
        s.replay.push(frame);
        s.replayBytes += bytes;
        while (
          (s.replayBytes > REPLAY_LIMIT || s.replay.length > REPLAY_FRAMES) &&
          s.replay.length > 1
        )
          s.replayBytes -= s.replay.shift()!.bytes;
        for (const ws of s.clients.keys()) this.pump(s, ws);
        this.flow(s);
      });
    });
    term.onExit(({ exitCode }) => {
      this.logger?.info("session.exited", { sessionId: id, exitCode });
      // Flush the emulator before announcing exit so the final output is not lost.
      screen.write("", () => {
        s.summary.status = "exited";
        s.summary.exitCode = exitCode;
        for (const ws of s.clients.keys()) this.pump(s, ws);
      });
    });
    return { ...summary };
  }
  attach(ws: WebSocket, id: string, cursor?: number): void {
    const s = this.require(id);
    const first = s.replay[0]?.cursor ?? s.cursor + 1;
    const resume =
      cursor !== undefined && cursor >= first - 1 && cursor <= s.cursor;
    const start = resume ? cursor! : s.cursor;
    if (!s.writer || s.writer.readyState !== s.writer.OPEN) s.writer = ws;
    const started = performance.now();
    const snapshot = resume ? undefined : s.serialize.serialize();
    if (!resume) {
      s.checkpoints++;
      s.checkpointMaxMs = Math.max(
        s.checkpointMaxMs,
        performance.now() - started,
      );
    }
    this.logger?.info("session.attached", {
      sessionId: id,
      requestedCursor: cursor,
      cursor: start,
      checkpoint: !resume,
      writable: s.writer === ws,
    });
    const bytes = snapshot === undefined ? 0 : Buffer.byteLength(snapshot);
    s.clients.set(ws, {
      sent: start,
      ack: resume ? start : -1,
      bytes,
      frames: snapshot === undefined ? [] : [{ cursor: start, bytes }],
    });
    send(ws, {
      type: "attached",
      session: { ...s.summary },
      cursor: start,
      snapshot,
      writable: s.writer === ws,
      notificationSequence: s.notificationSequence,
    });
    this.pump(s, ws);
  }
  takeControl(ws: WebSocket, id: string): void {
    const s = this.require(id);
    if (!s.clients.has(ws))
      throw new ServiceError(
        "Attach to the session before taking control",
        403,
      );
    if (s.writer === ws) return;
    this.logger?.info("session.control.transferred", { sessionId: id });
    if (s.writer)
      send(s.writer, { type: "ownership", sessionId: id, writable: false });
    s.writer = ws;
    send(ws, { type: "ownership", sessionId: id, writable: true });
  }
  detach(ws: WebSocket, id?: string): void {
    for (const s of this.sessions.values()) {
      if (id && s.summary.id !== id) continue;
      if (s.clients.delete(ws))
        this.logger?.info("session.detached", { sessionId: s.summary.id });
      if (s.writer === ws) {
        s.writer = undefined;
        const next = s.clients.keys().next().value;
        if (next) this.takeControl(next, s.summary.id);
      }
      this.flow(s);
    }
  }
  acknowledge(ws: WebSocket, id: string, cursor: number): void {
    const s = this.require(id),
      a = s.clients.get(ws);
    if (!a || cursor < a.ack || cursor > a.sent)
      throw new ServiceError("Invalid output acknowledgement", 400);
    a.ack = cursor;
    a.frames = a.frames.filter((f) => {
      if (f.cursor <= cursor) {
        a.bytes -= f.bytes;
        return false;
      }
      return true;
    });
    this.pump(s, ws);
  }
  input(ws: WebSocket, id: string, data: string): void {
    const s = this.requireWriter(ws, id);
    this.requireRunning(s);
    s.pty.write(data);
    s.inputBytes += Buffer.byteLength(data);
  }
  paste(
    id: string,
    commandId: string,
    text: string,
    sendReturn: boolean,
  ): void {
    const s = this.require(id);
    const fingerprint = crypto
      .createHash("sha256")
      .update(JSON.stringify([text, sendReturn]))
      .digest("hex");
    const prior = s.commands.get(commandId);
    if (prior !== undefined) {
      if (prior !== fingerprint)
        throw new ServiceError(
          "Command ID already used for different input",
          409,
        );
      this.logger?.info("input.deduplicated", { sessionId: id, commandId });
      return;
    }
    this.requireRunning(s);
    const normalized = text.replace(/\r\n|\r/g, "\n");
    // One PTY write, ordered with keyboard input. Only bracket paste when the application enables it.
    const payload = s.screen.modes.bracketedPasteMode
      ? `\x1b[200~${normalized}\x1b[201~`
      : normalized.replace(/\n/g, "\r");
    s.pty.write(payload + (sendReturn ? "\r" : ""));
    s.inputBytes += Buffer.byteLength(payload) + (sendReturn ? 1 : 0);
    this.logger?.info("input.submitted", {
      sessionId: id,
      commandId,
      characters: text.length,
      sendReturn,
    });
    s.commands.set(commandId, fingerprint);
    if (s.commands.size > 1000)
      s.commands.delete(s.commands.keys().next().value!);
  }
  resize(ws: WebSocket, id: string, cols: number, rows: number): void {
    const s = this.requireWriter(ws, id);
    this.requireRunning(s);
    if (s.summary.cols === cols && s.summary.rows === rows) return;
    this.logger?.info("session.resized", { sessionId: id, cols, rows });
    s.pty.resize(cols, rows);
    s.screen.resize(cols, rows);
    s.summary.cols = cols;
    s.summary.rows = rows;
    // Resize changes screen state outside the byte stream; invalidate replay and send a checkpoint.
    s.replay = [];
    s.replayBytes = 0;
    ++s.cursor;
    for (const client of s.clients.keys()) this.attach(client, id);
  }
  terminate(id: string): void {
    const s = this.require(id);
    this.logger?.info("session.end.requested", {
      sessionId: id,
      status: s.summary.status,
    });
    if (s.summary.status === "exited") {
      s.screen.dispose();
      this.sessions.delete(id);
      return;
    }
    if (!s.ending) {
      s.ending = true;
      const task = stopProcessTree(s.pty.pid, () => s.pty.kill()).catch(() => {
        try {
          s.pty.kill("SIGKILL");
        } catch {
          /* Process already exited. */
        }
      });
      this.terminations.add(task);
      void task.finally(() => this.terminations.delete(task));
    }
  }
  async stop(): Promise<void> {
    this.stopping = true;
    for (const s of this.sessions.values())
      if (s.summary.status === "running") this.terminate(s.summary.id);
    await Promise.allSettled(this.terminations);
  }
  recordDiagnostics(): void {
    for (const s of this.sessions.values()) {
      if (
        !s.inputBytes &&
        !s.outputBytes &&
        !s.pendingBytes &&
        !s.pauses &&
        !s.checkpoints
      )
        continue;
      this.logger?.info("traffic.summary", {
        sessionId: s.summary.id,
        inputBytes: s.inputBytes,
        outputBytes: s.outputBytes,
        pendingBytes: s.pendingBytes,
        outputFrames: s.outputFrames,
        checkpoints: s.checkpoints,
        checkpointMaxMs: Math.round(s.checkpointMaxMs),
        cols: s.summary.cols,
        rows: s.summary.rows,
        parserMaxMs: Math.round(s.parserMaxMs),
        parserPendingMs:
          s.pendingSince === undefined
            ? 0
            : Math.round(performance.now() - s.pendingSince),
        pauseMaxMs: Math.round(
          Math.max(
            s.pauseMaxMs,
            s.pauseStarted === undefined
              ? 0
              : performance.now() - s.pauseStarted,
          ),
        ),
        viewers: s.clients.size,
        cursor: s.cursor,
        outstandingBytes: [...s.clients.values()].reduce(
          (sum, client) => sum + client.bytes,
          0,
        ),
        outstandingFrames: [...s.clients.values()].reduce(
          (sum, client) => sum + client.frames.length,
          0,
        ),
        replayFrames: s.replay.length,
        pauses: s.pauses,
        paused: s.paused,
      });
      s.inputBytes = 0;
      s.outputBytes = 0;
      s.pauses = 0;
      s.outputFrames = 0;
      s.checkpoints = 0;
      s.checkpointMaxMs = 0;
      s.parserMaxMs = 0;
      s.pauseMaxMs = 0;
    }
  }
  private require(id: string): Session {
    const s = this.sessions.get(id);
    if (!s) throw new ServiceError(`Unknown session: ${id}`, 404);
    return s;
  }
  private requireRunning(s: Session): void {
    if (s.summary.status !== "running" || s.ending)
      throw new ServiceError("Session has ended", 409);
  }
  private requireWriter(ws: WebSocket, id: string): Session {
    const s = this.require(id);
    if (s.writer !== ws || !s.clients.has(ws))
      throw new ServiceError("Attach as the controlling viewer first", 403);
    return s;
  }
  private flow(s: Session): void {
    if (!s.paused && s.pendingBytes > WINDOW) {
      s.pauses++;
      s.paused = true;
      s.pauseStarted = performance.now();
      s.pty.pause();
    }
    if (s.paused && s.pendingBytes < WINDOW / 2) {
      s.paused = false;
      s.pauseMaxMs = Math.max(
        s.pauseMaxMs,
        performance.now() - (s.pauseStarted ?? performance.now()),
      );
      s.pauseStarted = undefined;
      s.pty.resume();
    }
  }
  private pump(s: Session, ws: WebSocket): void {
    const a = s.clients.get(ws);
    if (!a || ws.readyState !== ws.OPEN) return;
    if (a.bytes >= WINDOW || a.frames.length >= WINDOW_FRAMES) return;
    const first = s.replay[0]?.cursor ?? s.cursor + 1;
    if (a.sent < first - 1) {
      this.attach(ws, s.summary.id);
      return;
    }
    // Replay cursors are contiguous; resize invalidates the whole replay. Start
    // at the next unsent cursor rather than scanning history on every key echo/ACK.
    for (let index = a.sent - first + 1; index < s.replay.length; index++) {
      if (a.bytes >= WINDOW || a.frames.length >= WINDOW_FRAMES) break;
      const f = s.replay[index]!;
      send(ws, {
        type: "output",
        sessionId: s.summary.id,
        cursor: f.cursor,
        data: f.data,
        notificationSequence: f.notificationSequence,
      });
      a.sent = f.cursor;
      a.bytes += f.bytes;
      a.frames.push({ cursor: f.cursor, bytes: f.bytes });
    }
    if (s.summary.status === "exited" && a.sent === s.cursor)
      send(ws, {
        type: "exited",
        sessionId: s.summary.id,
        exitCode: s.summary.exitCode,
      });
  }
}
