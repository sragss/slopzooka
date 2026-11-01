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
  const payload = "\u007f\u001b[3~\b\t\u001b[D\u0003";
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
  const waitFor = async (marker: string) => {
    const deadline = Date.now() + 10_000;
    while (!output.includes(marker)) {
      assert.ok(Date.now() < deadline, `Timed out waiting for ${marker}`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  };
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
    sessions.attach(viewer, session.id);
    await waitFor("KEYS_READY");
    // Match the JSON round trip used by keyboard input on the terminal stream.
    const message = JSON.parse(
      JSON.stringify({ type: "input", data: payload }),
    );
    sessions.input(viewer, session.id, message.data);
    await waitFor(`KEYS_HEX:${Buffer.from(payload).toString("hex")}`);
  } finally {
    await sessions.stop();
    await fs.rm(home, { recursive: true, force: true });
  }
});
