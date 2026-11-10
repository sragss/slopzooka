import { createRequire } from "node:module";
import { appendFile } from "node:fs/promises";
const require = createRequire(
  new URL("../../apps/mac-companion/package.json", import.meta.url),
);
const { WebSocket } = require("ws");
export class Rpc {
  constructor(codex, socket, env, log) {
    this.events = [];
    this.pending = new Map();
    this.next = 1;
    this.writes = Promise.resolve();
    this.socket = new WebSocket(`ws+unix://${socket}:/`, {
      maxPayload: 16 * 1024 * 1024,
    });
    this.ready = new Promise((resolve, reject) => {
      this.socket.once("open", resolve);
      this.socket.once("error", reject);
    });
    this.done = new Promise((resolve) =>
      this.socket.once("close", (code) => {
        for (const { reject, timer } of this.pending.values()) {
          clearTimeout(timer);
          reject(new Error("RPC connection closed; outcome may be uncertain"));
        }
        this.pending.clear();
        resolve({ code });
      }),
    );
    this.record = (row) => {
      this.writes = this.writes.then(() =>
        appendFile(log, JSON.stringify({ at: Date.now(), ...row }) + "\n", {
          mode: 0o600,
        }),
      );
    };
    this.socket.on("error", (e) => this.record({ error: e.message }));
    this.socket.on("message", (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.id === this.dropReplyID && !m.method) {
        this.record({
          droppedReply: {
            id: m.id,
            fault: "acceptance reply withheld from adapter",
          },
        });
        this.socket.terminate();
        return;
      }
      this.record({ received: m });
      if (m.id !== undefined && !m.method && this.pending.has(m.id)) {
        const p = this.pending.get(m.id);
        this.pending.delete(m.id);
        clearTimeout(p.timer);
        m.error
          ? p.reject(
              Object.assign(new Error(m.error.message), { rpcError: m.error }),
            )
          : p.resolve(m.result);
      } else this.events.push(m);
    });
  }
  send(m) {
    this.record({ sent: m });
    this.socket.send(JSON.stringify(m));
  }
  async call(method, params = {}, timeout = 15000) {
    await this.ready;
    const id = this.next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC timed out: ${method}; outcome may be uncertain`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ id, method, params });
    });
  }
  async loseReply(method, params) {
    this.dropReplyID = this.next;
    return this.call(method, params);
  }
  async initialize() {
    const value = await this.call("initialize", {
      clientInfo: { name: "slz_worker_delivery_probe", version: "0.1.0" },
      capabilities: { experimentalApi: true },
    });
    this.send({ method: "initialized", params: {} });
    return value;
  }
  async close() {
    if (this.socket.readyState === WebSocket.OPEN) this.socket.close();
    else this.socket.terminate();
    const timer = setTimeout(() => this.socket.terminate(), 1500);
    await this.done;
    clearTimeout(timer);
    await this.writes;
  }
}
