import type { Terminal } from "@xterm/xterm";
import {
  PROTOCOL_VERSION,
  type ClientMessage,
  type ServerMessage,
} from "../../../packages/protocol/src/index.js";

export class TerminalConnection {
  private socket?: WebSocket;
  private renderTail: Promise<void> = Promise.resolve();
  private cursor?: number;
  private retry?: ReturnType<typeof setTimeout>;
  private handshake?: ReturnType<typeof setTimeout>;
  private readonly inputSubscription: { dispose(): void };
  private attempts = 0;
  private stopped = false;
  private writable = false;
  private running = false;
  private attached = false;
  constructor(
    private readonly terminal: Terminal,
    private readonly sessionId: string,
    private readonly status: (
      message: string,
      state: "connecting" | "running" | "exited" | "failed",
    ) => void,
    private readonly fit: () => void,
  ) {
    this.inputSubscription = terminal.onData((data) => {
      if (this.attached && this.writable && this.running)
        this.send({ type: "input", sessionId, data });
    });
  }
  connect(): void {
    if (
      this.stopped ||
      (this.socket && this.socket.readyState < WebSocket.CLOSING)
    )
      return;
    this.clearTimers();
    this.attached = false;
    this.writable = false;
    this.status("Connecting to your Mac…", "connecting");
    const url = new URL("/ws", location.href);
    url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(url);
    this.socket = ws;
    this.handshake = setTimeout(() => {
      if (this.socket === ws && !this.attached) ws.close();
    }, 10_000);
    ws.onmessage = (event) => {
      if (this.socket !== ws) return;
      try {
        const message = JSON.parse(String(event.data)) as ServerMessage;
        this.renderTail = this.renderTail
          .then(() => this.receive(message, ws))
          .catch(() => {
            // A retired connection cannot change the status of its replacement.
            if (this.isCurrent(ws))
              this.status("Could not restore terminal", "failed");
            ws.close();
          });
      } catch {
        this.status("Invalid response from companion", "failed");
        ws.close();
      }
    };
    ws.onclose = () => {
      if (this.socket !== ws || this.stopped) return;
      this.clearTimers();
      this.attached = false;
      this.writable = false;
      this.status(
        "Reconnecting to your Mac… Keep SlopZooka running.",
        "connecting",
      );
      this.retry = setTimeout(
        () => this.connect(),
        Math.min(10000, 300 * 2 ** this.attempts++) + Math.random() * 300,
      );
    };
    ws.onerror = () => {
      if (this.isCurrent(ws))
        this.status("Connection interrupted", "connecting");
    };
  }
  resize(): void {
    if (!this.attached || !this.writable || !this.running) return;
    this.fit();
    this.send({
      type: "resize",
      sessionId: this.sessionId,
      cols: this.terminal.cols,
      rows: this.terminal.rows,
    });
  }
  reconnect(): void {
    if (this.stopped) return;
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
    this.attached = false;
    this.writable = false;
    this.clearTimers();
    this.inputSubscription.dispose();
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
        if (!this.isCurrent(ws) || m.sessionId !== this.sessionId) return;
        this.writable = m.writable;
        this.status(
          this.running ? "Connected" : "Session ended",
          this.running ? "running" : "exited",
        );
        this.resize();
        break;
      case "hello":
        if (!this.isCurrent(ws)) return;
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
        this.status(
          this.running
            ? m.writable
              ? "Connected"
              : "Connected • read only"
            : "Session ended",
          this.running ? "running" : "exited",
        );
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
        this.status(
          m.code === "404"
            ? `This session is no longer available. Open a new terminal from the dashboard. (${m.code}: ${m.message})`
            : `${m.message} (${m.code})`,
          "failed",
        );
        if (m.code === "404") this.detach();
        break;
    }
  }
  private write(data: string): Promise<void> {
    return new Promise((resolve) => this.terminal.write(data, resolve));
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
