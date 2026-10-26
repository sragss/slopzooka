import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import headless from "@xterm/headless";
import type { WebSocket } from "ws";
import { SessionManager } from "../src/sessions.js";

test("terminal colors ignore launcher NO_COLOR and survive streaming and reconnect snapshots", async () => {
  const keys = [
    "NO_COLOR",
    "COLORTERM",
    "SHELL",
    "SLOPZOOKA_CODEX_COMMAND",
  ] as const;
  const previous = keys.map((key) => process.env[key]);
  const sessions = new SessionManager();
  const screen = new headless.Terminal({
    cols: 120,
    rows: 36,
    allowProposedApi: true,
  });
  try {
    process.env.NO_COLOR = "1";
    process.env.COLORTERM = "";
    process.env.SHELL = "/bin/sh";
    process.env.SLOPZOOKA_CODEX_COMMAND =
      `printf 'ENV=%s/%s/%s\\n' "$TERM" "$COLORTERM" "\${NO_COLOR-unset}"; ` +
      `printf '\\033[31mRED\\033[0m \\033[38;5;202mINDEXED\\033[0m \\033[38;2;12;120;240mRGB\\033[0m\\n'`;
    const session = sessions.create("workspace", os.tmpdir(), "codex");
    let stream = "";
    let snapshot = "";
    const viewer = (capture: (message: any) => void) =>
      ({
        OPEN: 1,
        readyState: 1,
        bufferedAmount: 0,
        send: (raw: string) => capture(JSON.parse(raw)),
      }) as unknown as WebSocket;
    const first = viewer((message) => {
      if (message.type === "output") stream += message.data;
    });
    sessions.attach(first, session.id);
    const deadline = Date.now() + 10_000;
    while (!stream.includes("RGB\x1b[0m")) {
      assert.ok(Date.now() < deadline, `Timed out: ${stream}`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.ok(stream.includes("ENV=xterm-256color/truecolor/unset"), stream);
    assert.ok(stream.includes("\x1b[31mRED"));
    assert.ok(stream.includes("\x1b[38;5;202mINDEXED"));
    assert.ok(stream.includes("\x1b[38;2;12;120;240mRGB"));
    sessions.detach(first);
    sessions.attach(
      viewer((message) => {
        if (message.type === "attached") snapshot = message.snapshot;
      }),
      session.id,
    );
    await new Promise<void>((resolve) => screen.write(snapshot, resolve));
    let checked = false;
    for (let row = 0; row < screen.buffer.active.length; row++) {
      const line = screen.buffer.active.getLine(row)!;
      const text = line.translateToString();
      if (!text.includes("RED INDEXED RGB")) continue;
      assert.equal(line.getCell(text.indexOf("RED"))!.getFgColor(), 1);
      assert.equal(line.getCell(text.indexOf("INDEXED"))!.getFgColor(), 202);
      const rgb = line.getCell(text.indexOf("RGB"))!;
      assert.ok(rgb.isFgRGB());
      assert.equal(rgb.getFgColor(), (12 << 16) | (120 << 8) | 240);
      checked = true;
    }
    assert.ok(checked, "reconnected screen must retain the colored output");
    assert.equal(
      process.env.NO_COLOR,
      "1",
      "host logging preference is unchanged",
    );
  } finally {
    await sessions.stop();
    screen.dispose();
    keys.forEach((key, index) => {
      if (previous[index] === undefined) delete process.env[key];
      else process.env[key] = previous[index];
    });
  }
});
