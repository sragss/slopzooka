// ../../packages/protocol/src/diagnostics.ts
var MAX_LOG_EVENT_BYTES = 8 * 1024;
var MAX_LOG_BATCH = 32;
var LOG_SOURCES = [
  "mac-companion",
  "session-service",
  "mac-menu",
  "vision-client",
  "browser"
];
var correlationKeys = [
  "hostId",
  "clientId",
  "actionId",
  "requestId",
  "sessionId",
  "workspaceId",
  "windowId",
  "commandId",
  "connectionId"
];
var validLogId = (value) => typeof value === "string" && /^[a-zA-Z0-9._:-]{1,120}$/.test(value);
var privateKey = /authorization|cookie|token|ticket|password|secret|api[_-]?key|credential|private[_-]?key|pairingCode|transcript|^(text|data|body|environment|payload|command)$/i;
function safeLogText(value) {
  return value.slice(0, 2048).replace(/\b(?:https?|wss?):\/\/[^\s"'<>]+/gi, (text) => {
    try {
      const url = new URL(text);
      return `${url.protocol}//${url.host}${url.pathname}`;
    } catch {
      return "[url]";
    }
  }).replace(/\bBearer\s+[^\s,;]+/gi, "Bearer [redacted]").replace(
    /\b(token|ticket|password|secret|api[_ -]?key|credentials?|private[_ -]?key|pairing[ -]?code|authorization)\s*[:=]\s*[^\s,;]+/gi,
    "$1=[redacted]"
  );
}
function logError(value, depth = 0) {
  try {
    if (!value || typeof value !== "object")
      return {
        message: safeLogText(
          typeof value === "string" ? value : "Unknown error"
        )
      };
    const error = value;
    const result = {
      message: safeLogText(
        typeof error.message === "string" ? error.message : "Unknown error"
      )
    };
    for (const key of ["name", "stack"])
      if (typeof error[key] === "string") result[key] = safeLogText(error[key]);
    if (typeof error.code === "string") result.code = safeLogText(error.code);
    else if (typeof error.code === "number" && Number.isFinite(error.code))
      result.code = error.code;
    if (error.cause !== void 0 && depth < 2)
      result.cause = logError(error.cause, depth + 1);
    return result;
  } catch {
    return { message: "Unreadable error details" };
  }
}
function safeLogFields(fields) {
  const result = /* @__PURE__ */ Object.create(null);
  for (const key of correlationKeys)
    if (validLogId(fields[key])) result[key] = fields[key];
  if (fields.error !== void 0) result.error = logError(fields.error);
  let remaining = 24;
  for (const key of Object.keys(fields)) {
    if (key === "error" || correlationKeys.includes(key))
      continue;
    if (remaining-- <= 0) break;
    const descriptor = Object.getOwnPropertyDescriptor(fields, key);
    if (!descriptor || !("value" in descriptor)) continue;
    const value = descriptor.value;
    if (privateKey.test(key)) result[key.slice(0, 80)] = "[redacted]";
    else if (typeof value === "string")
      result[key.slice(0, 80)] = safeLogText(value);
    else if (value === null || typeof value === "boolean" || typeof value === "number" && Number.isFinite(value))
      result[key.slice(0, 80)] = value;
  }
  return result;
}
function boundedLogEvent(event) {
  const result = {
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
    ...event.buildId ? { buildId: event.buildId } : {},
    ...event.runtimeId ? { runtimeId: event.runtimeId } : {},
    ...event.receivedAt ? { receivedAt: event.receivedAt } : {},
    ...event.clock ? { clock: event.clock } : {}
  };
  if (new TextEncoder().encode(JSON.stringify(result)).length > MAX_LOG_EVENT_BYTES) {
    result.fields = {
      truncated: true,
      ...Object.fromEntries(
        correlationKeys.filter((key) => validLogId(event.fields[key])).map((key) => [key, event.fields[key]])
      ),
      ...result.fields.error ? { error: result.fields.error } : {}
    };
    if (new TextEncoder().encode(JSON.stringify(result)).length > MAX_LOG_EVENT_BYTES)
      result.fields.error = {
        message: result.fields.error.message.slice(0, 256)
      };
  }
  return result;
}

// src/bug-report-draft.ts
var BUG_ISSUES_URL = "https://github.com/sragss/slopzooka/issues/new";
function bugReportBody(description2, around2, capture2) {
  const builds = [
    ...new Set(
      (capture2?.producers ?? []).filter((p) => LOG_SOURCES.includes(p.source)).map((p) => {
        const build = /^[a-f0-9]{64}$/.test(p.buildId ?? "") ? p.buildId : "unavailable";
        const runtime = /^(v|os-)\d+\.\d+\.\d+$/.test(p.runtimeId ?? "") ? ` (${p.runtimeId})` : "";
        return `- ${p.source}: ${build}${runtime}`;
      })
    )
  ].slice(0, 8);
  const id = capture2 && /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(capture2.reportId) ? capture2.reportId : void 0;
  const incomplete = capture2 && (capture2.flushIncomplete || capture2.coverage.truncated || capture2.coverage.unavailable.length > 0 || capture2.coverage.partialSegments > 0 || capture2.coverage.malformedRecords > 0);
  return [
    "## What happened",
    description2.trim(),
    "## Incident",
    `Time: ${new Date(around2).toISOString()}`,
    id ? `Local diagnostic report: ${id} (logs have not been uploaded).` : "No diagnostic snapshot is attached.",
    ...incomplete ? ["The local snapshot has incomplete coverage."] : [],
    ...builds.length ? ["## Builds", ...builds] : []
  ].join("\n\n");
}
function bugReportURL(title2, body2) {
  if (!title2.trim()) throw new Error("Enter a short summary.");
  const url = new URL(BUG_ISSUES_URL);
  url.searchParams.set("title", title2.trim());
  url.searchParams.set("body", body2);
  if (url.href.length > 7800)
    throw new Error(
      "Shorten the description to fit GitHub\u2019s issue draft link. Your local snapshot is still saved."
    );
  return url.href;
}

// src/log-events.ts
function logId() {
  const bytes2 = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues)
    globalThis.crypto.getRandomValues(bytes2);
  else
    for (let index = 0; index < bytes2.length; index++)
      bytes2[index] = Math.floor(Math.random() * 256);
  return Array.from(bytes2, (byte) => byte.toString(16).padStart(2, "0")).join(
    ""
  );
}
function eventLogger(source, sink, options = {}) {
  const instanceId = options.instanceId ?? logId();
  let sequence = 0;
  function scoped(component, fields = {}) {
    const bound = { ...fields };
    function write(level, event, fields2 = {}) {
      if (level === "debug" && !options.debug) return;
      try {
        sink({
          version: 1,
          source,
          instanceId,
          sequence: ++sequence,
          ts: (/* @__PURE__ */ new Date()).toISOString(),
          monotonicMs: performance.now(),
          level,
          component,
          event,
          buildId: options.buildId,
          runtimeId: options.runtimeId,
          fields: { ...options.context?.current(), ...bound, ...fields2 }
        });
      } catch {
      }
    }
    return {
      debug: (event, fields2) => write("debug", event, fields2),
      info: (event, fields2) => write("info", event, fields2),
      warn: (event, fields2) => write("warn", event, fields2),
      error: (event, fields2) => write("error", event, fields2),
      child: (fields2) => scoped(component, { ...bound, ...fields2 })
    };
  }
  return scoped;
}

// src/browser-logger.ts
var queue = [];
var bytes = 0;
var dropped = 0;
var sending = false;
var clock;
var size = (event) => new TextEncoder().encode(JSON.stringify(event)).length;
var browserLog = eventLogger(
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
      bytes -= queue.shift().bytes;
      dropped++;
    }
    queue.push({ event, bytes: length });
    bytes += length;
  },
  {
    buildId: true ? "9cfcec8baf2510865b82d35ffaa7917385a9f03ccc626b3e47c6b685f5573e52" : "unknown"
  }
);
var log = browserLog("diagnostics");
async function flushBrowserLogs() {
  if (sending || !queue.length) return;
  sending = true;
  try {
    let length = 0;
    const batch = [];
    for (const pending of queue.slice(0, MAX_LOG_BATCH)) {
      length += pending.bytes;
      if (length > 48 * 1024) break;
      batch.push(pending.event);
    }
    const response = await fetch("/api/diagnostics/events", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ version: 1, clock, events: batch }),
      signal: AbortSignal.timeout(4e3)
    });
    if (response.ok) {
      const sent = new Set(batch.map((event) => event.sequence));
      for (let index = queue.length - 1; index >= 0; index--) {
        if (sent.has(queue[index].event.sequence))
          bytes -= queue.splice(index, 1)[0].bytes;
      }
      if (dropped) {
        const count = dropped;
        dropped = 0;
        log.warn("logs.dropped", { count });
      }
    }
  } catch {
  } finally {
    sending = false;
  }
}
setInterval(() => void flushBrowserLogs(), 2e3);
window.addEventListener("online", () => void flushBrowserLogs());
window.addEventListener(
  "error",
  (event) => browserLog("browser").error("browser.error", {
    error: event.error ?? event.message
  })
);
window.addEventListener(
  "unhandledrejection",
  (event) => browserLog("browser").error("browser.unhandled-rejection", {
    error: event.reason
  })
);

// src/bug-report.ts
var log2 = browserLog("bug-report");
var $ = (id) => document.getElementById(id);
var form = $("report-form");
var description = $("description");
var title = $("title");
var download = $("download-report");
var body = document.createElement("input");
body.type = "hidden";
body.name = "body";
description.removeAttribute("name");
form.append(body);
var status = $("capture-status");
var retry = $("retry-capture");
var ticket = new URLSearchParams(location.hash.slice(1)).get("connect");
var requestedTime = new URLSearchParams(location.search).get("around");
var around = requestedTime && Number.isFinite(Date.parse(requestedTime)) ? new Date(requestedTime).toISOString() : (/* @__PURE__ */ new Date()).toISOString();
history.replaceState(null, "", location.pathname);
var capture;
var capturing = false;
function updatePreview() {
  $("public-preview").textContent = bugReportBody(
    description.value,
    around,
    capture
  );
}
form.oninput = updatePreview;
form.onsubmit = (event) => {
  try {
    const draft = bugReportBody(description.value, around, capture);
    bugReportURL(title.value, draft);
    body.value = draft;
    $("report-error").hidden = true;
    log2.info("bug-report.review.requested");
  } catch (error) {
    event.preventDefault();
    $("report-error").textContent = error instanceof Error ? error.message : "Could not prepare the draft.";
    $("report-error").hidden = false;
  }
};
async function saveCapture() {
  if (capturing) return;
  capturing = true;
  retry.hidden = true;
  status.textContent = "Saving a diagnostic snapshot on your Mac\u2026 You can report the bug while this finishes.";
  try {
    await flushBrowserLogs();
    const response = await fetch("/api/diagnostics/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ around }),
      signal: AbortSignal.timeout(3e4)
    });
    if (!response.ok)
      throw new Error(
        response.status === 401 ? "Connect this browser in the dashboard, then retry. You can still report the bug without a snapshot." : "The Mac could not save a snapshot. You can still report the bug, or retry."
      );
    const result = await response.json();
    if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(result.reportId))
      throw new Error("The Mac returned an invalid report. Try again.");
    capture = result;
    download.href = `/api/diagnostics/reports/${capture.reportId}`;
    download.hidden = false;
    status.textContent = "Snapshot saved on your Mac. Download it to inspect locally; it is not attached to the issue.";
    log2.info("bug-report.snapshot.saved", { reportId: capture.reportId });
  } catch (error) {
    status.textContent = error instanceof Error ? error.message : "Snapshot unavailable. You can still report the bug.";
    retry.hidden = false;
  } finally {
    capturing = false;
    updatePreview();
  }
}
retry.onclick = () => {
  void saveCapture();
};
updatePreview();
async function start() {
  if (ticket) {
    try {
      const response = await fetch("/api/pair/dashboard", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ticket }),
        signal: AbortSignal.timeout(1e4)
      });
      if (!response.ok)
        throw new Error(
          "Open Report a Bug again from SlopZooka to connect this browser."
        );
    } catch (error) {
      status.textContent = error instanceof Error ? error.message : "Connect this browser in the dashboard to save diagnostics.";
      retry.hidden = false;
      return;
    }
  }
  log2.info("bug-report.opened");
  await saveCapture();
}
void start();
