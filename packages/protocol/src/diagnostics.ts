// Diagnostics are additive and independent of the terminal protocol version.
export const DIAGNOSTICS_VERSION = 1;
export const MAX_LOG_EVENT_BYTES = 8 * 1024;
export const MAX_LOG_BATCH = 32;
export const LOG_LEVELS = ["debug", "info", "warn", "error"] as const;
export type LogLevel = (typeof LOG_LEVELS)[number];
export const LOG_SOURCES = [
  "mac-companion",
  "session-service",
  "mac-menu",
  "vision-client",
  "browser",
] as const;
export type LogSource = (typeof LOG_SOURCES)[number];
export type LogEvent = {
  version: 1;
  source: LogSource;
  instanceId: string;
  sequence: number;
  ts: string;
  monotonicMs: number;
  level: LogLevel;
  component: string;
  event: string;
  buildId?: string;
  runtimeId?: string;
  fields: Record<string, unknown>;
  // Assigned by the Mac, never trusted from a remote event.
  receivedAt?: string;
  // A batch-time observation, not a rewritten event timestamp.
  clock?: LogClock;
};

export type LogFields = Record<
  string,
  LogScalar | LogError | Error | undefined
>;
export type LogClock = {
  observedAt: string;
  offsetMs: number;
  uncertaintyMs: number;
};
export type LogScalar = string | number | boolean | null;
export type LogError = {
  name?: string;
  message: string;
  stack?: string;
  code?: LogScalar;
  cause?: LogError;
};
export const correlationKeys = [
  "hostId",
  "clientId",
  "actionId",
  "requestId",
  "sessionId",
  "workspaceId",
  "windowId",
  "commandId",
  "connectionId",
] as const;

export const validLogId = (value: unknown): value is string =>
  typeof value === "string" && /^[a-zA-Z0-9._:-]{1,120}$/.test(value);

export const validTimestamp = (value: unknown): value is string =>
  typeof value === "string" &&
  value.length <= 40 &&
  Number.isFinite(Date.parse(value));

export function isLogClock(value: unknown): value is LogClock {
  if (!value || typeof value !== "object") return false;
  const clock = value as LogClock;
  return (
    validTimestamp(clock.observedAt) &&
    typeof clock.offsetMs === "number" &&
    Number.isFinite(clock.offsetMs) &&
    typeof clock.uncertaintyMs === "number" &&
    Number.isFinite(clock.uncertaintyMs) &&
    clock.uncertaintyMs >= 0
  );
}

export function isLogEvent(value: unknown): value is LogEvent {
  if (!value || typeof value !== "object") return false;
  const e = value as LogEvent;
  return (
    e.version === DIAGNOSTICS_VERSION &&
    LOG_SOURCES.includes(e.source) &&
    validLogId(e.instanceId) &&
    Number.isSafeInteger(e.sequence) &&
    e.sequence > 0 &&
    validTimestamp(e.ts) &&
    (e.receivedAt === undefined || validTimestamp(e.receivedAt)) &&
    (e.buildId === undefined || validLogId(e.buildId)) &&
    (e.runtimeId === undefined || validLogId(e.runtimeId)) &&
    (e.clock === undefined || isLogClock(e.clock)) &&
    Number.isFinite(e.monotonicMs) &&
    e.monotonicMs >= 0 &&
    LOG_LEVELS.includes(e.level) &&
    typeof e.component === "string" &&
    e.component.length > 0 &&
    e.component.length <= 120 &&
    typeof e.event === "string" &&
    e.event.length > 0 &&
    e.event.length <= 160 &&
    !!e.fields &&
    typeof e.fields === "object" &&
    !Array.isArray(e.fields)
  );
}

const privateKey =
  /authorization|cookie|token|ticket|password|secret|api[_-]?key|credential|private[_-]?key|pairingCode|transcript|^(text|data|body|environment|payload|command)$/i;

export function safeLogText(value: string): string {
  return value
    .slice(0, 2048)
    .replace(/\b(?:https?|wss?):\/\/[^\s"'<>]+/gi, (text) => {
      try {
        const url = new URL(text);
        return `${url.protocol}//${url.host}${url.pathname}`;
      } catch {
        return "[url]";
      }
    })
    .replace(/\bBearer\s+[^\s,;]+/gi, "Bearer [redacted]")
    .replace(
      /\b(token|ticket|password|secret|api[_ -]?key|credentials?|private[_ -]?key|pairing[ -]?code|authorization)\s*[:=]\s*[^\s,;]+/gi,
      "$1=[redacted]",
    );
}

/** Rich errors have a fixed schema; arbitrary metadata is flat. */
export function logError(value: unknown, depth = 0): LogError {
  try {
    if (!value || typeof value !== "object")
      return {
        message: safeLogText(
          typeof value === "string" ? value : "Unknown error",
        ),
      };
    const error = value as Record<string, unknown>;
    const result: LogError = {
      message: safeLogText(
        typeof error.message === "string" ? error.message : "Unknown error",
      ),
    };
    for (const key of ["name", "stack"] as const)
      if (typeof error[key] === "string") result[key] = safeLogText(error[key]);
    if (typeof error.code === "string") result.code = safeLogText(error.code);
    else if (typeof error.code === "number" && Number.isFinite(error.code))
      result.code = error.code;
    if (error.cause !== undefined && depth < 2)
      result.cause = logError(error.cause, depth + 1);
    return result;
  } catch {
    return { message: "Unreadable error details" };
  }
}

export function safeLogFields(
  fields: Record<string, unknown>,
): Record<string, LogScalar | LogError> {
  const result: Record<string, LogScalar | LogError> = Object.create(null);
  // Attribution/correlation does not compete with arbitrary metadata for space.
  for (const key of correlationKeys)
    if (validLogId(fields[key])) result[key] = fields[key];
  if (fields.error !== undefined) result.error = logError(fields.error);
  let remaining = 24;
  for (const key of Object.keys(fields)) {
    if (key === "error" || (correlationKeys as readonly string[]).includes(key))
      continue;
    if (remaining-- <= 0) break;
    const descriptor = Object.getOwnPropertyDescriptor(fields, key);
    if (!descriptor || !("value" in descriptor)) continue;
    const value = descriptor.value;
    if (privateKey.test(key)) result[key.slice(0, 80)] = "[redacted]";
    else if (typeof value === "string")
      result[key.slice(0, 80)] = safeLogText(value);
    else if (
      value === null ||
      typeof value === "boolean" ||
      (typeof value === "number" && Number.isFinite(value))
    )
      result[key.slice(0, 80)] = value;
  }
  return result;
}

export function boundedLogEvent(event: LogEvent): LogEvent {
  const result: LogEvent = {
    version: 1,
    source: event.source,
    instanceId: event.instanceId,
    sequence: event.sequence,
    ts: event.ts,
    monotonicMs: event.monotonicMs,
    level: event.level,
    component: safeLogText(event.component).slice(0, 120),
    event: safeLogText(event.event).slice(0, 160),
    fields: safeLogFields(event.fields),
    ...(event.buildId ? { buildId: event.buildId } : {}),
    ...(event.runtimeId ? { runtimeId: event.runtimeId } : {}),
    ...(event.receivedAt ? { receivedAt: event.receivedAt } : {}),
    ...(event.clock ? { clock: event.clock } : {}),
  };
  if (
    new TextEncoder().encode(JSON.stringify(result)).length >
    MAX_LOG_EVENT_BYTES
  ) {
    // Preserve identity and useful error details before dropping bulky metadata.
    result.fields = {
      truncated: true,
      ...Object.fromEntries(
        correlationKeys
          .filter((key) => validLogId(event.fields[key]))
          .map((key) => [key, event.fields[key]]),
      ),
      ...(result.fields.error ? { error: result.fields.error } : {}),
    };
    if (
      new TextEncoder().encode(JSON.stringify(result)).length >
      MAX_LOG_EVENT_BYTES
    )
      result.fields.error = {
        message: (result.fields.error as LogError).message.slice(0, 256),
      };
  }
  return result;
}
