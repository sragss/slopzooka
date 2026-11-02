import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import headless from "@xterm/headless";
import type { WebSocket } from "ws";
import { observeTerminalNotifications } from "../src/terminal-notifications.js";
import { SessionManager } from "../src/sessions.js";

test("streaming terminal parser recognizes BEL, OSC 9 and OSC 777 without false bells", async () => {
  const screen = new headless.Terminal({ allowProposedApi: true });
  let alerts = 0;
  observeTerminalNotifications(screen, () => alerts++);
  const write = (text: string) =>
    new Promise<void>((resolve) => screen.write(text, resolve));
  try {
    await write("ordinary output\x07");
    assert.equal(alerts, 1);
    await write("\x1b]9;Finished");
    assert.equal(alerts, 1, "incomplete OSC must wait for its terminator");
    await write("\x07");
    assert.equal(
      alerts,
      2,
      "OSC's BEL terminator must not create a second alert",
    );
    await write("\x1b]777;notify;Claude Code;Needs input\x1b");
    await write("\\");
    assert.equal(alerts, 3);
    await write("\x1b]9;Done\x1b\\");
    assert.equal(alerts, 4);
    await write("\x1b]0;Window title\x07\x1b]2;Other title\x07");
    await write("\x1b]9;4;1;50\x07\x1b]777;other;payload\x07");
    await write("\x1b]9;Cancelled\x18");
    assert.equal(
      alerts,
      4,
      "titles, progress reports and cancelled OSCs are not alerts",
    );
  } finally {
    screen.dispose();
  }
});

test("session retains alerts across viewer disconnects and screen checkpoints", async () => {
  const sessions = new SessionManager();
  const messages: any[] = [];
  const viewer = {
    OPEN: 1,
    readyState: 1,
    bufferedAmount: 0,
    send(raw: string) {
      messages.push(JSON.parse(raw));
    },
  } as unknown as WebSocket;
  const until = async (condition: () => boolean) => {
    const deadline = Date.now() + 10000;
    while (!condition()) {
      assert.ok(Date.now() < deadline, "Timed out waiting for terminal output");
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  };
  try {
    const session = sessions.create("workspace", os.tmpdir(), null, undefined, {
      ...process.env,
      SHELL: "/bin/sh",
    });
    sessions.attach(viewer, session.id);
    const cursor = messages[0].cursor;
    sessions.input(
      viewer,
      session.id,
      "printf '\\007'; printf 'ALERT_%s\\n' ONE\r",
    );
    await until(() =>
      messages.some((m) => m.type === "output" && m.notificationSequence === 1),
    );
    sessions.detach(viewer);
    // The PTY continues producing alerts with no attached viewers.
    sessions.paste(
      session.id,
      "offline-alert",
      "printf '\\033]9;Done\\007'; printf 'ALERT_%s\\n' TWO",
      true,
    );
    let checkpoint: any;
    await until(() => {
      messages.length = 0;
      sessions.attach(viewer, session.id);
      checkpoint = messages.find((m) => m.type === "attached");
      sessions.detach(viewer);
      return checkpoint?.notificationSequence === 2;
    });
    assert.equal(checkpoint.notificationSequence, 2);
    assert.ok(
      !checkpoint.snapshot.includes("\x07"),
      "screen serialization alone loses notifications",
    );
    messages.length = 0;
    sessions.attach(viewer, session.id, cursor);
    assert.equal(
      messages[0].notificationSequence,
      2,
      "resume establishes current alert baseline before old output",
    );
    const frames = messages.filter((m) => m.type === "output");
    assert.ok(frames.some((m) => m.notificationSequence === 1));
    assert.ok(frames.some((m) => m.notificationSequence === 2));
    assert.equal(
      sessions.summaries().length,
      1,
      "attaching never creates another process",
    );
  } finally {
    await sessions.stop();
  }
});
