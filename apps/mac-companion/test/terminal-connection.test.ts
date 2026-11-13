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
  const notifications: unknown[] = [];
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
    (...notification) => notifications.push(notification),
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
      notificationSequence: 3,
      writable: true,
    });
    ws.receive({
      type: "output",
      sessionId: "s1",
      cursor: 1,
      data: "B",
      notificationSequence: 4,
    });
    ws.receive({
      type: "attached",
      session,
      cursor: 2,
      snapshot: "C",
      notificationSequence: 4,
      writable: true,
    });
    ws.receive({
      type: "output",
      sessionId: "s1",
      cursor: 3,
      data: "D",
      notificationSequence: 5,
    });
    assert.deepEqual(
      notifications,
      [
        [3, "first", false],
        [4, "first", true],
        [5, "first", true],
      ],
      "native alerts cannot wait for queued terminal writes in an unattended WebView",
    );
    assert.equal(
      rendered,
      "",
      "notification delivery does not acknowledge unrendered output",
    );
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
      notificationSequence: 6,
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
    assert.equal(
      notifications.length,
      4,
      "the current socket delivers its silent checkpoint before rendering",
    );
    reconnected.receive({
      type: "output",
      sessionId: "s1",
      cursor: 5,
      data: "late",
      notificationSequence: 7,
    });
    assert.equal(
      notifications.length,
      4,
      "retired sockets cannot notify their replacement",
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

test("stalled transports recover without close events, ignore retired attempts, and stop after removal", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const originalSocket = globalThis.WebSocket;
  const originalLocation = Object.getOwnPropertyDescriptor(
    globalThis,
    "location",
  );
  const sockets: StalledSocket[] = [];
  class StalledSocket {
    static OPEN = 1;
    static CLOSING = 2;
    readyState = 0;
    onmessage?: (event: { data: string }) => void;
    onclose?: (event: { code: number }) => void;
    onerror?: () => void;
    constructor() {
      sockets.push(this);
    }
    close() {
      this.readyState = 2;
    }
    send() {}
    receive(message: unknown) {
      this.onmessage?.({ data: JSON.stringify(message) });
    }
  }
  globalThis.WebSocket = StalledSocket as any;
  Object.defineProperty(globalThis, "location", {
    configurable: true,
    value: { href: "http://host/terminal", protocol: "http:" },
  });
  let disposals = 0;
  const status: string[] = [];
  const states: string[] = [];
  const terminal = {
    cols: 80,
    rows: 24,
    onData: () => ({
      dispose() {
        disposals++;
      },
    }),
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
    (message, state) => {
      status.push(message);
      states.push(state);
    },
    () => {},
  );
  const flush = async () => {
    for (let i = 0; i < 10; i++) await Promise.resolve();
  };
  try {
    connection.connect();
    assert.equal(states.at(-1), "connecting");
    t.mock.timers.tick(10_000);
    assert.equal(states.at(-1), "disconnected");
    assert.equal(sockets[0]!.readyState, 2);
    t.mock.timers.tick(1000);
    assert.equal(sockets.length, 2, "closing transport cannot strand retries");
    assert.equal(
      states.at(-1),
      "disconnected",
      "retries keep one stable lost-connection notice",
    );
    sockets[1]!.readyState = 1;
    sockets[0]!.onclose?.({ code: 1006 });
    t.mock.timers.tick(1000);
    assert.equal(sockets.length, 2, "late close cannot retire its replacement");
    t.mock.timers.tick(10_000);
    t.mock.timers.tick(1500);
    assert.equal(
      sockets.length,
      3,
      "an open socket that never attaches also retries",
    );
    sockets[2]!.onerror?.();
    t.mock.timers.tick(3000);
    assert.equal(sockets.length, 4, "errors retry without a close event");
    sockets[2]!.onerror?.();
    sockets[2]!.onclose?.({ code: 1006 });
    t.mock.timers.tick(3000);
    assert.equal(
      sockets.length,
      4,
      "retired events cannot disrupt the new attempt",
    );

    connection.reconnect();
    assert.equal(sockets.length, 5);
    const current = sockets.at(-1)!;
    current.readyState = 1;
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
      5,
      "retired timers cannot interrupt a healthy connection",
    );
    assert.equal(current.readyState, 1);
    current.receive({ type: "ownership", sessionId: "s1", writable: false });
    current.receive({
      type: "error",
      code: "403",
      message: "Read-only viewer",
    });
    await flush();
    assert.equal(
      states.at(-1),
      "running",
      "rejected in-flight input cannot turn a handoff into a connection failure",
    );
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
      5,
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

test("sampled input receipts and alerts bypass coalesced output parsing without logging input", async () => {
  const { eventLogger } = await import("../src/log-events.js");
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
    sent: any[] = [];
    onmessage?: (event: { data: string }) => void;
    constructor() {
      sockets.push(this);
    }
    send(raw: string) {
      this.sent.push(JSON.parse(raw));
    }
    close() {
      this.readyState = 3;
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
  const events: any[] = [];
  const notifications: unknown[] = [];
  let input: (data: string) => void = () => {};
  let finishWrite: (() => void) | undefined;
  const terminal = {
    cols: 80,
    rows: 24,
    onData(listener: (data: string) => void) {
      input = listener;
      return { dispose() {} };
    },
    onRender() {
      return { dispose() {} };
    },
    reset() {},
    resize() {},
    write(_text: string, done: () => void) {
      finishWrite = done;
    },
  };
  const connection = new TerminalConnection(
    terminal as any,
    "s1",
    () => {},
    () => {},
    (...notification) => notifications.push(notification),
    eventLogger("browser", (event) => events.push(event))("terminal"),
  );
  const flush = async () => {
    for (let i = 0; i < 10; i++) await Promise.resolve();
  };
  try {
    connection.connect();
    const ws = sockets[0]!;
    ws.receive({ type: "hello", version: 1, supportsInputAck: true });
    ws.receive({
      type: "attached",
      session: { id: "s1", status: "running" },
      cursor: 0,
      writable: true,
      notificationSequence: 0,
    });
    await flush();
    ws.receive({
      type: "output",
      sessionId: "s1",
      cursor: 1,
      data: "private-output",
      notificationSequence: 1,
    });
    ws.receive({
      type: "output",
      sessionId: "s1",
      cursor: 2,
      data: "private-output-two",
      notificationSequence: 2,
    });
    ws.receive({
      type: "output",
      sessionId: "s1",
      cursor: 3,
      data: "private-output-three",
      notificationSequence: 3,
    });
    assert.deepEqual(
      notifications,
      [
        [0, "legacy", false],
        [1, "legacy", true],
        [2, "legacy", true],
        [3, "legacy", true],
      ],
      "each alert arrives before coalescing and rendering, even when frames share one write",
    );
    await flush();
    assert.ok(finishWrite, "output parsing remains blocked until its callback");
    input("private-input");
    const probe = ws.sent.find((m) => m.type === "input").probeId;
    assert.ok(Number.isSafeInteger(probe));
    input("second-private-input");
    assert.equal(
      ws.sent.filter((m) => m.probeId !== undefined).length,
      1,
      "only one probe may be outstanding",
    );
    ws.receive({ type: "input-ack", sessionId: "s1", probeId: probe + 1 });
    ws.receive({
      type: "input-ack",
      sessionId: "wrong-session",
      probeId: probe,
    });
    ws.receive({ type: "input-ack", sessionId: "s1", probeId: probe });
    ws.receive({ type: "input-ack", sessionId: "s1", probeId: probe });
    connection.detach();
    const summary = events.find((e) => e.event === "latency.summary").fields;
    assert.equal(
      summary.inputAcks,
      1,
      "receipt is processed exactly once while output remains blocked",
    );
    assert.equal(summary.inputs, 2);
    assert.equal(summary.outputFrames, 3);
    assert.equal(
      summary.outputBatches,
      1,
      "consecutive output still shares one parser write",
    );
    assert.equal(summary.inputProbesInterrupted, undefined);
    assert.equal(
      ws.sent.some((m) => m.type === "ack" && m.cursor >= 1),
      false,
      "output is not acknowledged before parsing",
    );
    assert.ok(!JSON.stringify(events).includes("private-"));
    finishWrite!();
    await flush();
  } finally {
    connection.detach();
    globalThis.WebSocket = originalSocket;
    if (originalLocation)
      Object.defineProperty(globalThis, "location", originalLocation);
    else delete (globalThis as any).location;
  }
});
