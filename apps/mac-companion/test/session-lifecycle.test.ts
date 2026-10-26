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
      assert.equal(sessions.summaries()[0]?.status, "running");
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
