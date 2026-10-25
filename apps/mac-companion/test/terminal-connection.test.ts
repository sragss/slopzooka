import test from "node:test";
import assert from "node:assert/strict";
import { TerminalConnection } from "../src/terminal-connection.js";

test("terminal rendering serializes checkpoints with output and resumes from rendered cursor", async () => {
  const originalSocket = globalThis.WebSocket;
  const originalLocation = Object.getOwnPropertyDescriptor(
    globalThis,
    "location",
  );
  const sockets: FakeSocket[] = [];
  class FakeSocket {
    static OPEN = 1;
    static CLOSING = 2;
    readyState = 1;
    onmessage?: (event: { data: string }) => void;
    onclose?: () => void;
    onerror?: () => void;
    sent: any[] = [];
    constructor(_url: URL) {
      sockets.push(this);
    }
    send(raw: string) {
      this.sent.push(JSON.parse(raw));
    }
    close() {
      this.readyState = 3;
      this.onclose?.();
    }
    receive(message: unknown) {
      this.onmessage?.({ data: JSON.stringify(message) });
    }
  }
  globalThis.WebSocket = FakeSocket as any;
  Object.defineProperty(globalThis, "location", {
    configurable: true,
    value: { href: "http://host:7777/terminal", protocol: "http:" },
  });
  const operations: string[] = [];
  let rendered = "";
  const term = {
    cols: 80,
    rows: 24,
    onData() {
      return { dispose() {} };
    },
    resize() {
      operations.push("resize");
    },
    reset() {
      operations.push("reset");
      rendered = "";
    },
    write(text: string, done: () => void) {
      setTimeout(() => {
        operations.push(text);
        rendered += text;
        done();
      }, 10);
    },
  };
  const connection = new TerminalConnection(
    term as any,
    "s1",
    () => {},
    () => {},
  );
  const session = { id: "s1", cols: 80, rows: 24, status: "running" };
  try {
    connection.connect();
    const ws = sockets[0]!;
    ws.receive({ type: "hello", version: 1 });
    ws.receive({
      type: "attached",
      session,
      cursor: 0,
      snapshot: "A",
      writable: true,
    });
    ws.receive({ type: "output", sessionId: "s1", cursor: 1, data: "B" });
    ws.receive({
      type: "attached",
      session,
      cursor: 2,
      snapshot: "C",
      writable: true,
    });
    ws.receive({ type: "output", sessionId: "s1", cursor: 3, data: "D" });
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(rendered, "CD");
    assert.deepEqual(operations, [
      "reset",
      "resize",
      "A",
      "B",
      "reset",
      "resize",
      "C",
      "D",
    ]);
    assert.deepEqual(
      ws.sent.filter((m) => m.type === "ack").map((m) => m.cursor),
      [0, 1, 2, 3],
    );
    ws.close();
    await new Promise((r) => setTimeout(r, 650));
    const reconnected = sockets[1]!;
    assert.ok(reconnected);
    reconnected.receive({ type: "hello", version: 1 });
    await new Promise((r) => setTimeout(r, 10));
    assert.deepEqual(reconnected.sent[0], {
      type: "attach",
      sessionId: "s1",
      cursor: 3,
    });
    // A checkpoint can finish rendering after its socket closes and a replacement opens.
    reconnected.receive({
      type: "attached",
      session,
      cursor: 4,
      snapshot: "slow-checkpoint",
      writable: true,
    });
    reconnected.receive({ type: "ownership", sessionId: "s1", writable: true });
    await new Promise((r) => setTimeout(r, 1));
    reconnected.close();
    connection.connect();
    const replacement = sockets[2]!;
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(
      replacement.sent,
      [],
      "retired sockets must not resize or activate their replacement",
    );
    replacement.receive({ type: "hello", version: 1 });
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(
      replacement.sent[0].cursor,
      4,
      "resume includes bytes actually rendered before reconnection",
    );
  } finally {
    connection.detach();
    globalThis.WebSocket = originalSocket;
    if (originalLocation)
      Object.defineProperty(globalThis, "location", originalLocation);
    else delete (globalThis as any).location;
  }
});

test("stalled attachments retry once, explicit reconnect retires old timers, and detach releases input", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const originalSocket = globalThis.WebSocket;
  const originalLocation = Object.getOwnPropertyDescriptor(
    globalThis,
    "location",
  );
  const sockets: FakeSocket[] = [];
  class FakeSocket {
    static OPEN = 1;
    static CLOSING = 2;
    readyState = 1;
    onmessage?: (event: { data: string }) => void;
    onclose?: () => void;
    sent: any[] = [];
    constructor() {
      sockets.push(this);
    }
    send(raw: string) {
      this.sent.push(JSON.parse(raw));
    }
    close() {
      this.readyState = 3;
      this.onclose?.();
    }
    receive(message: unknown) {
      this.onmessage?.({ data: JSON.stringify(message) });
    }
  }
  globalThis.WebSocket = FakeSocket as any;
  Object.defineProperty(globalThis, "location", {
    configurable: true,
    value: { href: "http://host/terminal", protocol: "http:" },
  });
  let disposals = 0;
  const status: string[] = [];
  const terminal = {
    cols: 80,
    rows: 24,
    onData() {
      return {
        dispose() {
          disposals++;
        },
      };
    },
    reset() {},
    resize() {},
    write(_data: string, done: () => void) {
      done();
    },
  };
  const connection = new TerminalConnection(
    terminal as any,
    "s1",
    (message) => status.push(message),
    () => {},
  );
  const flush = async () => {
    for (let i = 0; i < 10; i++) await Promise.resolve();
  };
  try {
    connection.connect();
    t.mock.timers.tick(10_000);
    assert.equal(
      sockets[0]!.readyState,
      3,
      "a silent open socket cannot strand the terminal forever",
    );
    t.mock.timers.tick(1000);
    assert.equal(sockets.length, 2);
    connection.reconnect();
    assert.equal(sockets.length, 3);
    const current = sockets[2]!;
    current.receive({ type: "hello", version: 1 });
    current.receive({
      type: "attached",
      session: { id: "s1", cols: 80, rows: 24, status: "running" },
      writable: true,
      cursor: 0,
      snapshot: "",
    });
    await flush();
    t.mock.timers.tick(30_000);
    assert.equal(
      sockets.length,
      3,
      "retired retry and attachment timers cannot interrupt a healthy connection",
    );
    assert.equal(current.readyState, 1);
    current.receive({
      type: "error",
      code: "404",
      message: "Unknown session: s1",
    });
    await flush();
    assert.match(status.at(-1)!, /Open a new terminal/);
    assert.match(status.at(-1)!, /404: Unknown session: s1/);
    connection.detach();
    connection.reconnect();
    t.mock.timers.tick(30_000);
    assert.equal(
      sockets.length,
      3,
      "removed sessions do not reconnect forever",
    );
    assert.equal(disposals, 1);
  } finally {
    connection.detach();
    t.mock.timers.reset();
    globalThis.WebSocket = originalSocket;
    if (originalLocation)
      Object.defineProperty(globalThis, "location", originalLocation);
    else delete (globalThis as any).location;
  }
});
