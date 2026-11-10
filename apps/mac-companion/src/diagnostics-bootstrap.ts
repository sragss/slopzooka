// Preloaded before application imports. Fatal module-load/startup failures must
// remain diagnosable even when the structured runtime cannot initialize.
import fs from "node:fs";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import { boundedLogEvent } from "../../../packages/protocol/src/diagnostics.js";

process.on("uncaughtExceptionMonitor", (error) => {
  const directory = process.env.SLOPZOOKA_DIAGNOSTICS_DIR;
  const source = process.env.SLOPZOOKA_DIAGNOSTICS_ROLE;
  if (
    !directory ||
    (source !== "mac-companion" && source !== "session-service")
  )
    return;
  const role = path.join(directory, source);
  const temporary = path.join(role, "bootstrap.jsonl.tmp");
  try {
    fs.mkdirSync(role, { recursive: true, mode: 0o700 });
    let buildId = "unknown";
    try {
      buildId = createHash("sha256")
        .update(fs.readFileSync(process.argv[1]!))
        .digest("hex");
    } catch {}
    const event = boundedLogEvent({
      version: 1,
      source,
      instanceId: randomUUID(),
      sequence: 1,
      ts: new Date().toISOString(),
      monotonicMs: performance.now(),
      level: "error",
      component: "bootstrap",
      event: "process.bootstrap.failed",
      buildId,
      runtimeId:
        source === "session-service" ? process.argv[3] : process.version,
      fields: { error },
    });
    // Retain only the latest fatal record (8 KiB), with no inherited file handle.
    fs.writeFileSync(temporary, JSON.stringify(event) + "\n", { mode: 0o600 });
    fs.renameSync(temporary, path.join(role, "bootstrap.jsonl"));
  } catch {
    /* Preserve the application's normal fatal-error behavior. */
  } finally {
    try {
      fs.rmSync(temporary, { force: true });
    } catch {}
  }
});
