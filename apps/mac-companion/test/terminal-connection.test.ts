import test from "node:test";
import assert from "node:assert/strict";
import { TerminalConnection } from "../src/terminal-connection.js";
import { isClientMessage } from "../../../packages/protocol/src/index.js";

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
    ws.receive({ type: "hello", version: 1, serviceInstanceId: "first" });
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
    reconnected.receive({
      type: "hello",
      version: 1,
      serviceInstanceId: "first",
    });
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
    replacement.receive({
      type: "hello",
      version: 1,
      serviceInstanceId: "first",
    });
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(
      replacement.sent[0].cursor,
      4,
      "resume includes bytes actually rendered before reconnection",
    );
    replacement.close();
    connection.connect();
    const restartedService = sockets[3]!;
    restartedService.receive({
      type: "hello",
      version: 1,
      serviceInstanceId: "second",
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(
      restartedService.sent[0].cursor,
      undefined,
      "a new session-service instance cannot reuse an old screen cursor",
    );
    restartedService.receive({
      type: "attached",
      session,
      cursor: 0,
      writable: false,
    });
    await new Promise((resolve) => setTimeout(resolve, 10));
    const sentBefore = restartedService.sent.length;
    connection.takeControl();
    assert.equal(
      restartedService.sent.length,
      sentBefore,
      "takeover is not sent to older session services",
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
  let fittedSize = { cols: 80, rows: 24 };
  const status: string[] = [];
  const states: string[] = [];
  const ownership: { readOnly?: boolean; canTakeControl?: boolean }[] = [];
  let input: (data: string) => void;
  const terminal = {
    cols: 80,
    rows: 24,
    onData(callback: (data: string) => void) {
      input = callback;
      return {
        dispose() {
          disposals++;
        },
      };
    },
    reset() {},
    resize(cols: number, rows: number) {
      this.cols = cols;
      this.rows = rows;
    },
    write(_data: string, done: () => void) {
      done();
    },
  };
  const connection = new TerminalConnection(
    terminal as any,
    "s1",
    (message, state, readOnly, canTakeControl) => {
      ownership.push({ readOnly, canTakeControl });
      status.push(message);
      states.push(state);
    },
    () => {
      terminal.cols = fittedSize.cols;
      terminal.rows = fittedSize.rows;
    },
  );
  const flush = async () => {
    for (let i = 0; i < 10; i++) await Promise.resolve();
  };
  try {
    connection.connect();
    assert.equal(states.at(-1), "connecting");
    t.mock.timers.tick(10_000);
    assert.equal(
      sockets[0]!.readyState,
      3,
      "a silent open socket cannot strand the terminal forever",
    );
    assert.equal(states.at(-1), "disconnected");
    t.mock.timers.tick(1000);
    assert.equal(sockets.length, 2);
    assert.equal(
      states.at(-1),
      "disconnected",
      "retries keep one stable lost-connection notice",
    );
    connection.reconnect();
    assert.equal(sockets.length, 3);
    const current = sockets[2]!;
    current.receive({ type: "hello", version: 1, supportsTakeControl: true });
    current.receive({
      type: "attached",
      session: { id: "s1", cols: 80, rows: 24, status: "running" },
      writable: true,
      cursor: 0,
      snapshot: "",
    });
    await flush();
    assert.equal(
      states.at(-1),
      "running",
      "reattachment dismisses the connection notice",
    );
    t.mock.timers.tick(30_000);
    assert.equal(
      sockets.length,
      3,
      "retired retry and attachment timers cannot interrupt a healthy connection",
    );
    assert.equal(current.readyState, 1);
    // Extreme zoom-out must not send dimensions the companion will reject, or
    // leave the local emulator wrapping at a different width from the PTY.
    fittedSize = { cols: 1328, rows: 832 };
    connection.resize();
    const extremeResize = current.sent.at(-1);
    assert.ok(isClientMessage(extremeResize));
    assert.equal(extremeResize.type, "resize");
    assert.equal(terminal.cols, extremeResize.cols);
    assert.equal(terminal.rows, extremeResize.rows);
    assert.ok(
      terminal.cols < fittedSize.cols && terminal.rows < fittedSize.rows,
    );
    fittedSize = { cols: 80, rows: 24 };
    connection.resize();
    assert.equal(terminal.cols, 80, "Zooming back in restores the fitted grid");
    assert.equal(terminal.rows, 24);
    current.receive({ type: "ownership", sessionId: "s1", writable: false });
    await flush();
    assert.deepEqual(ownership.at(-1), {
      readOnly: true,
      canTakeControl: true,
    });
    const sent = current.sent.length;
    input!("blocked");
    connection.resize();
    assert.equal(
      current.sent.length,
      sent,
      "revoked viewers cannot send input or resize",
    );
    connection.takeControl();
    assert.deepEqual(current.sent.at(-1), {
      type: "take-control",
      sessionId: "s1",
    });
    input!("still blocked");
    assert.equal(
      current.sent.length,
      sent + 1,
      "claiming control waits for the service's confirmation",
    );
    current.receive({ type: "ownership", sessionId: "s1", writable: true });
    await flush();
    assert.deepEqual(ownership.at(-1), {
      readOnly: false,
      canTakeControl: false,
    });
    input!("allowed");
    assert.deepEqual(current.sent.at(-1), {
      type: "input",
      sessionId: "s1",
      data: "allowed",
    });
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
