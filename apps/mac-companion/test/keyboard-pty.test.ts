import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { SessionManager } from "../src/sessions.js";

test("Codex-profile PTY receives terminal editing/control bytes unchanged", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-keyboard-pty-"));
  const sessions = new SessionManager();
  // A raw reader exercises the same launch/PTY input path without starting an agent.
  const payload =
    "AZ!_é😀\u007f\u001b[3~\b\t\u001b[D\u0003\u001b[1;3A\u001bOP\u001b[15;2~\u001b[1;6D";
  await fs.writeFile(
    path.join(home, "probe.py"),
    `import os, tty
tty.setraw(0)
os.write(1, b'KEYS_READY\\n')
data = b''
while len(data) < ${Buffer.byteLength(payload)}:
    data += os.read(0, ${Buffer.byteLength(payload)} - len(data))
os.write(1, b'\\nKEYS_HEX:' + data.hex().encode() + b'\\n')
`,
  );
  try {
    const session = sessions.create(
      "keyboard-probe",
      home,
      "codex",
      undefined,
      {
        ...process.env,
        SHELL: "/bin/sh",
        SLOPZOOKA_CODEX_COMMAND: "/usr/bin/python3 -u ./probe.py",
      },
    );
    const terminal = attach(sessions, session.id);
    await terminal.waitFor("KEYS_READY");
    // Match the JSON round trip used by keyboard input on the terminal stream.
    const message = JSON.parse(
      JSON.stringify({ type: "input", data: payload }),
    );
    terminal.input(message.data);
    await terminal.waitFor(`KEYS_HEX:${Buffer.from(payload).toString("hex")}`);
  } finally {
    await sessions.stop();
    await fs.rm(home, { recursive: true, force: true });
  }
});

test("Control-C interrupts the foreground process while preserving its shell", async () => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-sigint-"));
  const sessions = new SessionManager();
  await fs.writeFile(
    path.join(home, "probe.py"),
    `import signal, sys, time

def interrupted(signum, frame):
    print('FOREGROUND_INTERRUPTED', flush=True)
    sys.exit(0)

signal.signal(signal.SIGINT, interrupted)
print('FOREGROUND_READY', flush=True)
while True:
    time.sleep(60)
`,
  );
  try {
    const session = sessions.create("sigint-probe", home, null, undefined, {
      ...process.env,
      SHELL: "/bin/sh",
    });
    const terminal = attach(sessions, session.id);
    terminal.input(
      "printf '\\nSHELL_PID=%s\\n' \"$$\"; /usr/bin/python3 -u ./probe.py\r",
    );
    const before = await terminal.waitFor("FOREGROUND_READY");
    const pid = /SHELL_PID=(\d+)/.exec(before)?.[1];
    assert.ok(
      pid,
      "Shell must report its PID before running the foreground command",
    );
    // Send through the ordinary writable viewer path, not kill()/paste/an HTTP action.
    terminal.input("\x03");
    await terminal.waitFor("FOREGROUND_INTERRUPTED");
    terminal.input("printf '\\nSHELL_ALIVE=%s\\n' \"$$\"\r");
    await terminal.waitFor(`SHELL_ALIVE=${pid}`);
    assert.equal(
      sessions.summaries().find((s) => s.id === session.id)?.status,
      "running",
    );
  } finally {
    await sessions.stop();
    await fs.rm(home, { recursive: true, force: true });
  }
});

function attach(sessions: SessionManager, id: string) {
  let output = "";
  const viewer = {
    OPEN: 1,
    readyState: 1,
    bufferedAmount: 0,
    send(raw: string) {
      const message = JSON.parse(raw);
      if (message.snapshot) output += message.snapshot;
      if (message.type === "output") output += message.data;
    },
  } as unknown as import("ws").WebSocket;
  sessions.attach(viewer, id);
  return {
    input(data: string) {
      sessions.input(viewer, id, data);
    },
    async waitFor(marker: string) {
      const deadline = Date.now() + 10_000;
      while (!output.includes(marker)) {
        assert.ok(Date.now() < deadline, `Timed out waiting for ${marker}`);
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      return output;
    },
  };
}

test(
  "tiny PTY frames stay bounded per viewer while a healthy writer advances beyond replay eviction",
  { timeout: 20000 },
  async () => {
    const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-tiny-frames-"));
    const summaries: Record<string, any>[] = [];
    const sessions = new SessionManager({
      info(event: string, fields: Record<string, any>) {
        if (event === "traffic.summary") summaries.push(fields);
      },
    } as any);
    await fs.writeFile(
      path.join(home, "probe.py"),
      `import os, tty
tty.setraw(0)
for i in range(5000):
    os.write(1, b'.')
    os.read(0, 1)
os.write(1, b'TINY_DONE')
`,
    );
    const messages: any[] = [];
    let received = "";
    let healthy: import("ws").WebSocket;
    const viewer = (consume: (message: any) => void) =>
      ({
        OPEN: 1,
        readyState: 1,
        bufferedAmount: 0,
        send(raw: string) {
          queueMicrotask(() => consume(JSON.parse(raw)));
        },
      }) as unknown as import("ws").WebSocket;
    try {
      const session = sessions.create("tiny-frames", home, "codex", undefined, {
        ...process.env,
        SHELL: "/bin/sh",
        SLOPZOOKA_CODEX_COMMAND: "/usr/bin/python3 -u ./probe.py",
      });
      healthy = viewer((message) => {
        if (message.type !== "output" && message.type !== "attached") return;
        sessions.acknowledge(healthy, session.id, message.cursor);
        received += message.data ?? message.snapshot ?? "";
        if (message.type === "output" && message.data.endsWith("."))
          sessions.input(healthy, session.id, "x");
      });
      const slow = viewer((message) => messages.push(message));
      sessions.attach(healthy, session.id);
      sessions.attach(slow, session.id);
      const deadline = Date.now() + 15000;
      while (!received.includes("TINY_DONE")) {
        assert.ok(
          Date.now() < deadline,
          "Healthy viewer must not be blocked by the slow viewer",
        );
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      const frames = messages.filter((m) => m.type === "output");
      assert.equal(
        frames.length,
        255,
        "checkpoint plus output must stop at 256 unacknowledged frames",
      );
      sessions.recordDiagnostics();
      const summary = summaries.at(-1)!;
      assert.ok(summary.replayFrames <= 4096);
      assert.ok(
        summary.outputFrames >= 5000,
        "handshake produces distinct real PTY frames",
      );
      sessions.acknowledge(slow, session.id, frames.at(-1).cursor);
      await new Promise((resolve) => setTimeout(resolve, 0));
      const checkpoint = messages.filter((m) => m.type === "attached").at(-1);
      assert.ok(
        checkpoint.snapshot.includes("TINY_DONE"),
        "expired tiny-frame history recovers from the current screen",
      );
      assert.equal(
        sessions.summaries().length,
        1,
        "recovery must reuse the existing process",
      );
    } finally {
      await sessions.stop();
      await fs.rm(home, { recursive: true, force: true });
    }
  },
);
