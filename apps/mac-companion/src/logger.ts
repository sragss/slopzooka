import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { eventLogger, type EventLogger, type LogFields } from "./log-events.js";
import { LogStore, type LogRole, type LogStoreOptions } from "./log-store.js";

export type Logger = Pick<EventLogger, "info" | "warn" | "error">;
const context = new AsyncLocalStorage<LogFields>();
export const logContext = {
  current: () => context.getStore() ?? {},
  without: <T>(run: () => T): T => context.exit(run),
  run: <T>(fields: LogFields, run: () => T): T =>
    context.run({ ...context.getStore(), ...fields }, run),
};

/** One store per process. Components receive lightweight scoped loggers. */
export function createDiagnostics(
  source: LogRole,
  options: LogStoreOptions & { runtimeId?: string; instanceId?: string } = {},
) {
  const store = new LogStore(source, options);
  const logger = eventLogger(
    source,
    (event) => {
      store.append(event);
    },
    {
      instanceId: options.instanceId,
      buildId: options.runtimeId ?? buildId(),
      runtimeId: options.runtimeId ?? process.version,
      debug: process.env.SLOPZOOKA_LOG_LEVEL === "debug",
      context: logContext,
    },
  );
  return { logger, store };
}

export type Diagnostics = ReturnType<typeof createDiagnostics>;

// Packaged hosts are bundled; development fingerprints the source directories too.
function buildId(): string {
  try {
    const hash = createHash("sha256"),
      entry = process.argv[1]!;
    hash.update(readFileSync(entry));
    if (entry.endsWith(".ts")) {
      for (const directory of [
        path.dirname(entry),
        path.resolve(import.meta.dirname, "../../../packages/protocol/src"),
      ])
        for (const name of readdirSync(directory).sort())
          if (name.endsWith(".ts"))
            hash.update(name).update(readFileSync(path.join(directory, name)));
    }
    return hash.digest("hex");
  } catch {
    return "unknown";
  }
}
