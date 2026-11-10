import { logError } from "../../../packages/protocol/src/diagnostics.js";
import { eventLogger, logId } from "./log-events.js";
import {
  MAX_LOG_BATCH,
  boundedLogEvent,
  type LogEvent,
  type LogClock,
} from "../../../packages/protocol/src/diagnostics.js";

type PendingEvent = { event: LogEvent; bytes: number };
const queue: PendingEvent[] = [];
let bytes = 0,
  dropped = 0,
  sending = false;
let clock: LogClock | undefined;
declare const __SLOPZOOKA_BUILD_ID__: string;
const size = (event: LogEvent) =>
  new TextEncoder().encode(JSON.stringify(event)).length;
export const browserLog = eventLogger(
  "browser",
  (event) => {
    event = boundedLogEvent(event);
    const bridge = window.webkit?.messageHandlers?.diagnostics;
    if (bridge) {
      bridge.postMessage(event);
      return;
    }
    const length = size(event);
    while (queue.length && bytes + length > 256 * 1024) {
      bytes -= queue.shift()!.bytes;
      dropped++;
    }
    queue.push({ event, bytes: length });
    bytes += length;
  },
  {
    buildId:
      typeof __SLOPZOOKA_BUILD_ID__ === "string"
        ? __SLOPZOOKA_BUILD_ID__
        : "unknown",
  },
);
const log = browserLog("diagnostics");

export async function flushBrowserLogs() {
  if (sending || !queue.length) return;
  sending = true;
  try {
    let length = 0;
    const batch: LogEvent[] = [];
    for (const pending of queue.slice(0, MAX_LOG_BATCH)) {
      length += pending.bytes;
      if (length > 48 * 1024) break;
      batch.push(pending.event);
    }
    const response = await fetch("/api/diagnostics/events", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ version: 1, clock, events: batch }),
      signal: AbortSignal.timeout(4000),
    });
    if (response.ok) {
      const sent = new Set(batch.map((event) => event.sequence));
      for (let index = queue.length - 1; index >= 0; index--) {
        if (sent.has(queue[index]!.event.sequence))
          bytes -= queue.splice(index, 1)[0]!.bytes;
      }
      if (dropped) {
        const count = dropped;
        dropped = 0;
        log.warn("logs.dropped", { count });
      }
    }
  } catch {
    /* Keep the bounded batch for reconnect; never log the logging request. */
  } finally {
    sending = false;
  }
}
setInterval(() => void flushBrowserLogs(), 2000);
window.addEventListener("online", () => void flushBrowserLogs());
window.addEventListener("error", (event) =>
  browserLog("browser").error("browser.error", {
    error: event.error ?? event.message,
  }),
);
window.addEventListener("unhandledrejection", (event) =>
  browserLog("browser").error("browser.unhandled-rejection", {
    error: event.reason,
  }),
);

/** First-party control requests only. No headers, bodies, or arbitrary URLs in events. */
export async function loggedFetch(
  route: string,
  init: RequestInit = {},
): Promise<Response> {
  const method = init.method ?? "GET",
    actionId = logId();
  const fields = { actionId, method, route: route.split("?")[0] };
  const log = browserLog("http", fields),
    started = performance.now();
  if (method !== "GET") log.info("http.started");
  try {
    const headers = new Headers(init.headers);
    headers.set("X-SlopZooka-Action-ID", actionId);
    const response = await fetch(route, { ...init, headers });
    const durationMs = performance.now() - started;
    const serverTime = Date.parse(
      response.headers.get("X-SlopZooka-Time") ?? "",
    );
    if (Number.isFinite(serverTime))
      clock = {
        observedAt: new Date().toISOString(),
        offsetMs: serverTime - (Date.now() - durationMs / 2),
        uncertaintyMs: durationMs / 2,
      };
    const result = {
      status: response.status,
      durationMs,
      requestId: response.headers.get("X-SlopZooka-Request-ID"),
    };
    if (!response.ok) log.warn("http.completed", result);
    else if (method !== "GET") log.info("http.completed", result);
    return response;
  } catch (error) {
    log.error("http.failed", {
      error: logError(error),
      durationMs: performance.now() - started,
    });
    throw error;
  }
}
