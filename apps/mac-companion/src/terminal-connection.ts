import { logError } from "../../../packages/protocol/src/diagnostics.js";
import type { Terminal } from "@xterm/xterm";
import type { EventLogger } from "./log-events.js";
import { TerminalPerformance } from "./terminal-performance.js";
import {
  MAX_TERMINAL_DIMENSION,
  PROTOCOL_VERSION,
  type ClientMessage,
  type ServerMessage,
} from "../../../packages/protocol/src/index.js";

type QueuedOutput = {
  message: Extract<ServerMessage, { type: "output" }>;
  socket: WebSocket;
  frames: number;
  receivedAt: number;
};

export class TerminalConnection {
  private socket?: WebSocket;
  private renderTail: Promise<void> = Promise.resolve();
  private pendingOutput?: QueuedOutput;
  private readonly performance?: TerminalPerformance;
  private cursor?: number;
  private serviceInstanceId?: string;
  private lastNotification?: { sequence: number; instance: string };
  private retry?: ReturnType<typeof setTimeout>;
  private handshake?: ReturnType<typeof setTimeout>;
  private readonly inputSubscription: { dispose(): void };
  private attempts = 0;
  private stopped = false;
  private writable = false;
  private running = false;
  private attached = false;
  private lostConnection = false;
  private supportsTakeControl = false;
  private supportsInputAck = false;
  constructor(
    private readonly terminal: Terminal,
    private readonly sessionId: string,
    private readonly status: (
      message: string,
      state: "connecting" | "disconnected" | "running" | "exited" | "failed",
      readOnly?: boolean,
      canTakeControl?: boolean,
    ) => void,
    private readonly fit: () => void,
    private readonly notification: (
      sequence: number,
      serviceInstanceId: string,
      audible: boolean,
    ) => void = () => {},
    private log?: EventLogger,
  ) {
    if (log)
      this.performance = new TerminalPerformance(terminal, () => this.log);
    this.inputSubscription = terminal.onData((data) => {
      if (this.attached && this.writable && this.running)
        this.send({
          type: "input",
          sessionId,
          data,
          probeId: this.performance?.submitted(this.supportsInputAck),
        });
    });
  }
  connect(): void {
    if (
      this.stopped ||
      (this.socket && this.socket.readyState < WebSocket.CLOSING)
    )
      return;
    this.clearTimers();
    this.log?.info("connection.connecting", { attempt: this.attempts });
    this.attached = false;
    this.writable = false;
    this.status(
      this.lostConnection
        ? "Lost companion connection."
        : "Connecting to your Mac…",
      this.lostConnection ? "disconnected" : "connecting",
    );
    const url = new URL("/ws", location.href);
    url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(url);
    let notificationInstance: string | undefined;
    this.socket = ws;
    this.handshake = setTimeout(() => {
      if (this.socket === ws && !this.attached) this.retryConnection(ws);
    }, 10_000);
    ws.onmessage = (event) => {
      if (this.socket !== ws) return;
      try {
        const message = JSON.parse(String(event.data)) as ServerMessage;
        // Alert counters describe Mac state, not rendered bytes. An unattended
        // WebView can stall xterm writes; notify native UI before that queue.
        // Wire order still establishes the silent attach baseline before replay.
        if (this.isCurrent(ws)) {
          if (message.type === "hello" && message.version === PROTOCOL_VERSION)
            notificationInstance = message.serviceInstanceId ?? "legacy";
          if (notificationInstance !== undefined) {
            if (
              message.type === "attached" &&
              message.session.id === this.sessionId
            )
              this.reportNotification(
                message.notificationSequence,
                notificationInstance,
                false,
              );
            if (
              message.type === "output" &&
              message.sessionId === this.sessionId
            )
              this.reportNotification(
                message.notificationSequence,
                notificationInstance,
                true,
              );
          }
        }
        // A sampled PTY-submission receipt must not wait behind output parsing.
        if (message.type === "input-ack") {
          if (message.sessionId === this.sessionId)
            this.performance?.acknowledged(message.probeId);
          return;
        }
        let output: QueuedOutput | undefined;
        if (message.type === "output" && message.sessionId === this.sessionId) {
          this.performance?.queued(message.data.length);
          const pending = this.pendingOutput;
          if (
            pending?.socket === ws &&
            pending.message.data.length + message.data.length <= 64 * 1024
          ) {
            pending.message.data += message.data;
            pending.message.cursor = message.cursor;
            pending.message.notificationSequence =
              message.notificationSequence ??
              pending.message.notificationSequence;
            pending.frames++;
            return;
          }
          output = {
            message,
            socket: ws,
            frames: 1,
            receivedAt: performance.now(),
          };
        }
        // Control/checkpoint messages are ordering barriers. Only consecutive
        // output queued for the same socket can share one xterm parser write.
        this.pendingOutput = output;
        this.renderTail = this.renderTail
          .then(() => {
            if (this.pendingOutput === output) this.pendingOutput = undefined;
            if (output)
              this.performance?.started(
                output.frames,
                output.message.data.length,
                output.receivedAt,
              );
            return this.receive(message, ws);
          })
          .catch((error) => {
            this.log?.error("render.failed", { error: logError(error) });
            // A retired connection cannot change the status of its replacement.
            if (this.isCurrent(ws))
              this.status("Could not restore terminal", "failed");
            ws.close();
          });
      } catch (error) {
        this.log?.error("protocol.invalid", { error: logError(error) });
        this.status("Invalid response from companion", "failed");
        ws.close();
      }
    };
    ws.onclose = (event) => {
      this.log?.info("connection.closed", { code: event.code });
      this.retryConnection(ws);
    };
    ws.onerror = () => {
      this.retryConnection(ws);
    };
  }
  private retryConnection(ws: WebSocket): void {
    if (this.socket !== ws || this.stopped) return;
    this.clearTimers();
    // WebKit may never deliver close after an interrupted handshake. Retire
    // the transport before closing it, so retries never depend on that event.
    this.socket = undefined;
    this.attached = false;
    this.writable = false;
    this.performance?.disconnected();
    this.lostConnection = true;
    this.log?.warn("connection.retrying", {
      attempt: this.attempts,
      cursor: this.cursor,
    });
    this.status("Lost companion connection.", "disconnected");
    ws.close();
    this.retry = setTimeout(
      () => this.connect(),
      Math.min(10000, 300 * 2 ** this.attempts++) + Math.random() * 300,
    );
  }
  resize(): void {
    if (!this.attached || !this.writable || !this.running) return;
    this.fit();
    // Small page zoom can fit more cells than the protocol permits. Keep the
    // emulator and PTY on the same bounded grid instead of sending an invalid resize.
    const cols = Math.max(
      2,
      Math.min(MAX_TERMINAL_DIMENSION, this.terminal.cols),
    );
    const rows = Math.max(
      2,
      Math.min(MAX_TERMINAL_DIMENSION, this.terminal.rows),
    );
    if (cols !== this.terminal.cols || rows !== this.terminal.rows)
      this.terminal.resize(cols, rows);
    this.send({
      type: "resize",
      sessionId: this.sessionId,
      cols,
      rows,
    });
  }
  takeControl(): void {
    this.log?.info("control.requested");
    if (
      this.attached &&
      this.running &&
      !this.writable &&
      this.supportsTakeControl
    )
      this.send({ type: "take-control", sessionId: this.sessionId });
  }
  reconnect(): void {
    if (this.stopped) return;
    this.performance?.disconnected();
    this.socket?.close();
    // Retire the old socket immediately; a delayed close cannot schedule a second retry.
    this.socket = undefined;
    this.connect();
  }
  private clearTimers(): void {
    clearTimeout(this.retry);
    clearTimeout(this.handshake);
    this.retry = undefined;
    this.handshake = undefined;
  }
  detach(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.log?.info("connection.detached", { cursor: this.cursor });
    this.attached = false;
    this.writable = false;
    this.clearTimers();
    this.inputSubscription.dispose();
    this.performance?.dispose();
    this.send({ type: "detach", sessionId: this.sessionId });
    this.socket?.close();
  }
  private isCurrent(ws: WebSocket): boolean {
    return (
      !this.stopped && this.socket === ws && ws.readyState === WebSocket.OPEN
    );
  }
  private async receive(m: ServerMessage, ws: WebSocket): Promise<void> {
    if (this.stopped) return;
    switch (m.type) {
      case "ownership":
        this.log?.info("ownership.changed", { writable: m.writable });
        if (!this.isCurrent(ws) || m.sessionId !== this.sessionId) return;
        this.writable = m.writable;
        this.publishOwnership();
        this.resize();
        break;
      case "hello":
        if (!this.isCurrent(ws)) return;
        this.log = this.log?.child({
          connectionId: m.connectionId,
          serviceInstanceId: m.serviceInstanceId,
        });
        this.log?.info("connection.accepted", {
          supportsInputAck: m.supportsInputAck === true,
        });
        if (
          m.serviceInstanceId &&
          this.serviceInstanceId &&
          m.serviceInstanceId !== this.serviceInstanceId
        )
          this.cursor = undefined;
        this.serviceInstanceId = m.serviceInstanceId;
        this.supportsTakeControl = m.supportsTakeControl === true;
        this.supportsInputAck = m.supportsInputAck === true;
        if (m.version !== PROTOCOL_VERSION) {
          this.status(
            `Update SlopZooka on both devices, then reopen this terminal. Protocol mismatch: expected ${PROTOCOL_VERSION}, received ${m.version}.`,
            "failed",
          );
          this.detach();
          return;
        }
        if (this.socket === ws && ws.readyState === WebSocket.OPEN)
          this.send({
            type: "attach",
            sessionId: this.sessionId,
            cursor: this.cursor,
          });
        break;
      case "attached":
        if (m.session.id !== this.sessionId) return;
        this.log?.info("session.attached", {
          cursor: m.cursor,
          checkpoint: m.snapshot !== undefined,
          writable: m.writable,
        });
        if (m.snapshot !== undefined) {
          this.terminal.reset();
          this.terminal.resize(m.session.cols, m.session.rows);
          await this.write(m.snapshot);
          this.ack(ws, m.cursor);
        }
        if (!this.isCurrent(ws)) return;
        clearTimeout(this.handshake);
        this.handshake = undefined;
        this.attempts = 0;
        this.running = m.session.status === "running";
        this.writable = m.writable;
        this.attached = true;
        this.lostConnection = false;
        this.publishOwnership();
        this.resize();
        break;
      case "output":
        if (m.sessionId !== this.sessionId) return;
        await this.write(m.data);
        this.ack(ws, m.cursor);
        break;
      case "exited":
        if (!this.isCurrent(ws) || m.sessionId !== this.sessionId) return;
        this.running = false;
        this.status(`Session ended (${m.exitCode ?? "terminated"})`, "exited");
        break;
      case "error":
        if (!this.isCurrent(ws)) return;
        this.log?.warn("protocol.rejected", {
          code: m.code,
          message: m.message,
        });
        // Input already in flight when control moves is an ordinary read-only transition.
        if (
          m.code === "403" &&
          this.attached &&
          this.running &&
          !this.writable
        ) {
          this.publishOwnership();
          break;
        }
        this.status(
          m.code === "404"
            ? `This session is no longer available. Open a new terminal from the dashboard. (${m.code}: ${m.message})`
            : `${m.message} (${m.code})`,
          "failed",
        );
        if (m.code === "404") this.detach();
        break;
      case "input-ack":
        break; // Handled on receipt, independently of the render queue.
    }
  }
  private publishOwnership(): void {
    const readOnly = this.running && !this.writable;
    this.status(
      this.running
        ? readOnly
          ? "Connected • read only"
          : "Connected"
        : "Session ended",
      this.running ? "running" : "exited",
      readOnly,
      readOnly && this.supportsTakeControl,
    );
  }
  private reportNotification(
    sequence: number | undefined,
    instance: string,
    audible: boolean,
  ): void {
    if (!Number.isSafeInteger(sequence) || sequence! < 0) return;
    if (
      this.lastNotification?.instance === instance &&
      sequence! <= this.lastNotification.sequence
    )
      return;
    this.lastNotification = { sequence: sequence!, instance };
    this.notification(sequence!, instance, audible);
  }

  private write(data: string): Promise<void> {
    const started = performance.now();
    return new Promise((resolve) =>
      this.terminal.write(data, () => {
        this.performance?.parsed(started);
        resolve();
      }),
    );
  }
  private ack(ws: WebSocket, cursor: number): void {
    // The cursor describes bytes rendered in this emulator, even if the connection just closed.
    this.cursor = cursor;
    if (this.isCurrent(ws))
      this.send({ type: "ack", sessionId: this.sessionId, cursor });
  }
  private send(message: ClientMessage): void {
    if (this.socket?.readyState === WebSocket.OPEN)
      this.socket.send(JSON.stringify(message));
  }
}
