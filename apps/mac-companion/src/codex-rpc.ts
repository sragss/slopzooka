import { WebSocket } from "ws";
import { ServiceError } from "./errors.js";

export type NativeMessage = {
  id?: number | string;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: { message: string; code: number };
};
/** Private owned-runtime connection. No transcript logging or automatic mutation retries. */
export class CodexRPC {
  private readonly socket: WebSocket;
  private next = 1;
  private pending = new Map<
    number,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      timer: NodeJS.Timeout;
    }
  >();
  readonly ready: Promise<void>;
  constructor(
    socketPath: string,
    private readonly receive: (message: NativeMessage) => void = () => {},
  ) {
    this.socket = new WebSocket(`ws+unix://${socketPath}:/`, {
      maxPayload: 8 * 1024 * 1024,
    });
    this.ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new ServiceError("Codex connection timed out", 503));
        this.socket.terminate();
      }, 5000);
      this.socket.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      this.socket.once("error", () => {
        clearTimeout(timer);
        reject(new ServiceError("Codex connection unavailable", 503));
      });
    });
    this.socket.on("error", () => {});
    this.socket.on("close", () => {
      for (const item of this.pending.values()) {
        clearTimeout(item.timer);
        item.reject(
          new ServiceError(
            "Codex disconnected; delivery may be uncertain",
            503,
          ),
        );
      }
      this.pending.clear();
      this.receive({ method: "slopzooka/disconnected" });
    });
    this.socket.on("message", (raw) => {
      let message: NativeMessage;
      try {
        message = JSON.parse(raw.toString()) as NativeMessage;
      } catch {
        this.socket.close(1002);
        return;
      }
      if (!message || typeof message !== "object") return;
      const pending =
        typeof message.id === "number" && !message.method
          ? this.pending.get(message.id)
          : undefined;
      if (pending) {
        this.pending.delete(message.id as number);
        clearTimeout(pending.timer);
        if (message.error)
          pending.reject(
            new ServiceError(
              `Codex rejected ${message.error.code}: ${message.error.message}`,
              409,
            ),
          );
        else pending.resolve(message.result);
      } else this.receive(message);
    });
  }
  async initialize() {
    await this.call("initialize", {
      clientInfo: { name: "slopzooka_coordinator", version: "0.1.0" },
      capabilities: { experimentalApi: true },
    });
    this.send({ method: "initialized", params: {} });
  }
  send(value: unknown) {
    if (this.socket.readyState !== WebSocket.OPEN)
      throw new ServiceError(
        "Codex connection unavailable; action was not sent",
        503,
      );
    this.socket.send(JSON.stringify(value));
  }
  async call<T = unknown>(method: string, params: unknown = {}): Promise<T> {
    await this.ready;
    if (this.socket.readyState !== WebSocket.OPEN)
      throw new ServiceError("Codex connection unavailable", 503);
    const id = this.next++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new ServiceError(
            "Codex reply timed out; outcome may be uncertain",
            503,
          ),
        );
      }, 15000);
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        timer,
      });
      this.send({ id, method, params });
    });
  }
  get connected() {
    return this.socket.readyState === WebSocket.OPEN;
  }
  close() {
    this.socket.terminate();
  }
}
