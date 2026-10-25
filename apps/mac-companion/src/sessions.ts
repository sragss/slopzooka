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

const REPLAY_LIMIT = 512 * 1024;
const WINDOW = 128 * 1024;
type Frame = { cursor: number; data: string; bytes: number };
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
  replay: Frame[];
  replayBytes: number;
  clients: Map<WebSocket, Attachment>;
  writer?: WebSocket;
  pendingBytes: number;
  commands: Map<string, string>;
  paused: boolean;
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

/** Owns processes independently of viewers. Survives client disconnects, not host restarts. */
export class SessionManager {
  private readonly sessions = new Map<string, Session>();
  private readonly terminations = new Set<Promise<void>>();
  private stopping = false;
  summaries(): SessionSummary[] {
    return [...this.sessions.values()].map((s) => ({ ...s.summary }));
  }
  create(
    workspaceId: string,
    cwd: string,
    profile: TuiProfile | null,
    id = crypto.randomUUID(),
  ): SessionSummary {
    if (this.stopping)
      throw new ServiceError("Companion is shutting down", 503);
    const existing = this.sessions.get(id);
    if (existing) {
      if (
        existing.summary.workspaceId !== workspaceId ||
        existing.summary.profile !== profile
      )
        throw new ServiceError(
          "Session ID already used for a different launch",
          409,
        );
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
      codex: process.env.SLOPZOOKA_CODEX_COMMAND ?? "codex",
      claude: process.env.SLOPZOOKA_CLAUDE_COMMAND ?? "claude",
      opencode: process.env.SLOPZOOKA_OPENCODE_COMMAND ?? "opencode",
    };
    const term = pty.spawn(
      process.env.SHELL ?? "/bin/zsh",
      profile ? ["-lc", commands[profile]] : ["-l"],
      {
        cwd,
        cols: summary.cols,
        rows: summary.rows,
        name: "xterm-256color",
        env: { ...process.env, TERM: "xterm-256color" },
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
      replay: [],
      replayBytes: 0,
      clients: new Map(),
      pendingBytes: 0,
      commands: new Map(),
      paused: false,
      ending: false,
    };
    this.sessions.set(id, s);
    term.onData((data) => {
      const bytes = Buffer.byteLength(data);
      s.pendingBytes += bytes;
      this.flow(s);
      screen.write(data, () => {
        s.pendingBytes -= bytes;
        const frame = { cursor: ++s.cursor, data, bytes };
        s.replay.push(frame);
        s.replayBytes += bytes;
        while (s.replayBytes > REPLAY_LIMIT && s.replay.length > 1)
          s.replayBytes -= s.replay.shift()!.bytes;
        for (const ws of s.clients.keys()) this.pump(s, ws);
        this.flow(s);
      });
    });
    term.onExit(({ exitCode }) => {
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
    const snapshot = resume ? undefined : s.serialize.serialize();
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
    });
    this.pump(s, ws);
  }
  detach(ws: WebSocket, id?: string): void {
    for (const s of this.sessions.values()) {
      if (id && s.summary.id !== id) continue;
      s.clients.delete(ws);
      if (s.writer === ws) {
        s.writer = s.clients.keys().next().value;
        if (s.writer)
          send(s.writer, {
            type: "ownership",
            sessionId: s.summary.id,
            writable: true,
          });
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
      return;
    }
    this.requireRunning(s);
    const normalized = text.replace(/\r\n|\r/g, "\n");
    // One PTY write, ordered with keyboard input. Only bracket paste when the application enables it.
    const payload = s.screen.modes.bracketedPasteMode
      ? `\x1b[200~${normalized}\x1b[201~`
      : normalized.replace(/\n/g, "\r");
    s.pty.write(payload + (sendReturn ? "\r" : ""));
    s.commands.set(commandId, fingerprint);
    if (s.commands.size > 1000)
      s.commands.delete(s.commands.keys().next().value!);
  }
  resize(ws: WebSocket, id: string, cols: number, rows: number): void {
    const s = this.requireWriter(ws, id);
    this.requireRunning(s);
    if (s.summary.cols === cols && s.summary.rows === rows) return;
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
      s.paused = true;
      s.pty.pause();
    }
    if (s.paused && s.pendingBytes < WINDOW / 2) {
      s.paused = false;
      s.pty.resume();
    }
  }
  private pump(s: Session, ws: WebSocket): void {
    const a = s.clients.get(ws);
    if (!a || ws.readyState !== ws.OPEN) return;
    if (a.bytes >= WINDOW) return;
    const first = s.replay[0]?.cursor ?? s.cursor + 1;
    if (a.sent < first - 1) {
      this.attach(ws, s.summary.id);
      return;
    }
    for (const f of s.replay) {
      if (f.cursor <= a.sent) continue;
      if (a.bytes >= WINDOW) break;
      send(ws, {
        type: "output",
        sessionId: s.summary.id,
        cursor: f.cursor,
        data: f.data,
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
