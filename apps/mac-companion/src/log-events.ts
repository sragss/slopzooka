import {
  type LogEvent,
  type LogLevel,
  type LogSource,
  type LogFields,
} from "../../../packages/protocol/src/diagnostics.js";

export type { LogFields };

// randomUUID is unavailable on the headset's plain-HTTP LAN origin. These IDs
// are correlation metadata, never credentials; getRandomValues works there.
export function logId(): string {
  const bytes = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues)
    globalThis.crypto.getRandomValues(bytes);
  else
    for (let index = 0; index < bytes.length; index++)
      bytes[index] = Math.floor(Math.random() * 256);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}
export type EventLogger = {
  debug(event: string, fields?: LogFields): void;
  info(event: string, fields?: LogFields): void;
  warn(event: string, fields?: LogFields): void;
  error(event: string, fields?: LogFields): void;
  child(fields: LogFields): EventLogger;
};

/** Portable callsite API; only the sink knows about files, HTTP, or WebKit. */
export function eventLogger(
  source: LogSource,
  sink: (event: LogEvent) => void,
  options: {
    instanceId?: string;
    buildId?: string;
    runtimeId?: string;
    debug?: boolean;
    context?: { current(): LogFields };
  } = {},
): (component: string, fields?: LogFields) => EventLogger {
  const instanceId = options.instanceId ?? logId();
  let sequence = 0;
  function scoped(component: string, fields: LogFields = {}): EventLogger {
    const bound = { ...fields };
    function write(level: LogLevel, event: string, fields: LogFields = {}) {
      if (level === "debug" && !options.debug) return;
      try {
        sink({
          version: 1,
          source,
          instanceId,
          sequence: ++sequence,
          ts: new Date().toISOString(),
          monotonicMs: performance.now(),
          level,
          component,
          event,
          buildId: options.buildId,
          runtimeId: options.runtimeId,
          fields: { ...options.context?.current(), ...bound, ...fields },
        });
      } catch {
        /* Diagnostics never change application behavior. */
      }
    }
    return {
      debug: (event, fields) => write("debug", event, fields),
      info: (event, fields) => write("info", event, fields),
      warn: (event, fields) => write("warn", event, fields),
      error: (event, fields) => write("error", event, fields),
      child: (fields) => scoped(component, { ...bound, ...fields }),
    };
  }
  return scoped;
}
