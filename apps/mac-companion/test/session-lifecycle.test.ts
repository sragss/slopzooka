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
