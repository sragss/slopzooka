import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import { SessionManager } from "../src/sessions.js";

test("shutdown permanently closes session admission", async () => {
  const sessions = new SessionManager();
  try {
    const stopping = sessions.stop();
    assert.throws(
      () => sessions.create("workspace", os.tmpdir(), null),
      /shutting down/,
    );
    await stopping;
    assert.throws(
      () => sessions.create("workspace", os.tmpdir(), null),
      /shutting down/,
    );
  } finally {
    await sessions.stop();
  }
});

for (const exitCode of [0, 7]) {
  test(`agent exit ${exitCode} leaves a usable shell until explicitly exited`, async () => {
    const previous = process.env.SLOPZOOKA_CODEX_COMMAND;
    process.env.SLOPZOOKA_CODEX_COMMAND = `printf 'AGENT_FINISHED\\n'; exit ${exitCode}`;
    const sessions = new SessionManager();
    try {
      const session = sessions.create("workspace", os.tmpdir(), "codex");
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
      sessions.attach(viewer, session.id);
      const waitFor = async (condition: () => boolean) => {
        const deadline = Date.now() + 10_000;
        while (!condition()) {
          assert.ok(Date.now() < deadline, `Timed out; output: ${output}`);
          await new Promise((resolve) => setTimeout(resolve, 20));
        }
      };
      await waitFor(() => output.includes("AGENT_FINISHED"));
      // Avoid mistaking echoed input for executed output: the marker is split in the command.
      sessions.input(viewer, session.id, "printf 'SHELL_%s\\n' READY\r");
      await waitFor(() => output.includes("SHELL_READY"));
      assert.equal(sessions.summaries()[0]?.status, "running", output);
      sessions.input(viewer, session.id, "exit 0\r");
      await waitFor(() => sessions.summaries()[0]?.status === "exited");
      assert.equal(sessions.summaries()[0]?.exitCode, 0);
    } finally {
      await sessions.stop();
      if (previous === undefined) delete process.env.SLOPZOOKA_CODEX_COMMAND;
      else process.env.SLOPZOOKA_CODEX_COMMAND = previous;
    }
  });
}

test("agent resolution uses interactive shell PATH rather than an older login-only install", async () => {
  const fs = await import("node:fs/promises");
  const path = await import("node:path");
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-shell-path-"));
  const keys = ["SHELL", "ZDOTDIR", "SLOPZOOKA_CODEX_COMMAND"] as const;
  const previous = keys.map((key) => process.env[key]);
  const sessions = new SessionManager();
  try {
    for (const name of ["old", "current"]) {
      await fs.mkdir(path.join(home, name));
      await fs.writeFile(
        path.join(home, name, "codex"),
        `#!/bin/sh\nprintf '${name.toUpperCase()}_CODEX\\n'\n`,
        { mode: 0o755 },
      );
    }
    await fs.writeFile(
      path.join(home, ".zprofile"),
      'export PATH="$ZDOTDIR/old:/usr/bin:/bin"\n',
    );
    await fs.writeFile(
      path.join(home, ".zshrc"),
      'export PATH="$ZDOTDIR/current:$PATH"\n',
    );
    process.env.SHELL = "/bin/zsh";
    process.env.ZDOTDIR = home;
    delete process.env.SLOPZOOKA_CODEX_COMMAND;
    const session = sessions.create("workspace", home, "codex");
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
    sessions.attach(viewer, session.id);
    const deadline = Date.now() + 10_000;
    while (!output.includes("CURRENT_CODEX")) {
      assert.ok(
        !output.includes("OLD_CODEX"),
        "must not launch the stale login-only executable",
      );
      assert.ok(Date.now() < deadline, `Timed out: ${output}`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(sessions.summaries()[0]?.status, "running", output);
  } finally {
    await sessions.stop();
    keys.forEach((key, index) => {
      if (previous[index] === undefined) delete process.env[key];
      else process.env[key] = previous[index];
    });
    await fs.rm(home, { recursive: true, force: true });
  }
});
