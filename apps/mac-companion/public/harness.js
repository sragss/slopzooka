// ../../packages/protocol/src/diagnostics.ts
var MAX_LOG_EVENT_BYTES = 8 * 1024;
var MAX_LOG_BATCH = 32;
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
    buildId: true ? "5aeae31713dd470468681993eb82b7f726c147520631e30a3a6f9b8ea2b50298" : "unknown"
  }
);
var log = browserLog("diagnostics");
async function flush() {
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
setInterval(() => void flush(), 2e3);
window.addEventListener("online", () => void flush());
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
async function loggedFetch(route, init = {}) {
  const method = init.method ?? "GET", actionId = logId();
  const fields = { actionId, method, route: route.split("?")[0] };
  const log3 = browserLog("http", fields), started = performance.now();
  if (method !== "GET") log3.info("http.started");
  try {
    const headers = new Headers(init.headers);
    headers.set("X-SlopZooka-Action-ID", actionId);
    const response = await fetch(route, { ...init, headers });
    const durationMs = performance.now() - started;
    const serverTime = Date.parse(
      response.headers.get("X-SlopZooka-Time") ?? ""
    );
    if (Number.isFinite(serverTime))
      clock = {
        observedAt: (/* @__PURE__ */ new Date()).toISOString(),
        offsetMs: serverTime - (Date.now() - durationMs / 2),
        uncertaintyMs: durationMs / 2
      };
    const result = {
      status: response.status,
      durationMs,
      requestId: response.headers.get("X-SlopZooka-Request-ID")
    };
    if (!response.ok) log3.warn("http.completed", result);
    else if (method !== "GET") log3.info("http.completed", result);
    return response;
  } catch (error) {
    log3.error("http.failed", {
      error: logError(error),
      durationMs: performance.now() - started
    });
    throw error;
  }
}

// src/harness.ts
var log2 = browserLog("harness");
var sections = {
  sessions: "Terminals",
  workspaces: "Workspaces",
  frontends: "Frontends"
};
var $ = (id) => document.getElementById(id);
var dashboardTicket = new URLSearchParams(location.hash.slice(1)).get(
  "connect"
);
if (dashboardTicket)
  history.replaceState(null, "", location.pathname + location.search);
var section = "sessions";
var paired = false;
var refreshing = false;
var busy = 0;
var data = { sessions: [], workspaces: [], frontends: [] };
var signatures = /* @__PURE__ */ new Map();
var showServices = false;
function message(id, text = "") {
  delete $(id).dataset.detail;
  $(id).textContent = text;
  $(id).hidden = !text;
}
function failure(id, error, guidance) {
  log2.warn("action.failed", {
    surface: id,
    errorType: error instanceof Error ? error.name : "unknown"
  });
  const detail = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  const element = $(id);
  if (element.dataset.detail === detail) return;
  element.dataset.detail = detail;
  element.replaceChildren(document.createTextNode(guidance));
  const details = document.createElement("details");
  const summary = document.createElement("summary");
  summary.textContent = "Details";
  const pre = document.createElement("pre");
  pre.textContent = detail;
  details.append(summary, pre);
  element.append(details);
  element.hidden = false;
}
function connection(text, connected = false) {
  $("connection-label").textContent = text;
  document.body.dataset.connected = String(connected);
}
function gate(authorized) {
  paired = authorized;
  $("loading").hidden = true;
  $("pairing").hidden = authorized;
  $("dashboard").hidden = !authorized;
  if (!authorized) {
    $("add-dialog").close();
    connection("Pairing required");
    for (const key of Object.keys(sections)) $(key + "-count").textContent = "";
  }
}
async function api(path, body, method = body ? "POST" : "GET") {
  let response;
  try {
    response = await loggedFetch(path, {
      method,
      signal: AbortSignal.timeout(3e4),
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : void 0
    });
  } catch (error) {
    throw new Error(
      `${method} ${path}: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error }
    );
  }
  if (response.status === 401) gate(false);
  const text = await response.text();
  let result;
  try {
    result = JSON.parse(text);
  } catch (error) {
    throw new Error(
      `${method} ${path} \u2014 HTTP ${response.status}: Invalid JSON response. ${String(error)}
${text.slice(0, 2048)}`,
      { cause: error }
    );
  }
  if (!response.ok)
    throw new Error(
      `${method} ${path} \u2014 HTTP ${response.status}: ${result.error ?? response.statusText}`
    );
  return result;
}
function row(title, detail) {
  const li = document.createElement("li");
  li.className = "row";
  const copy = document.createElement("div");
  copy.className = "row-copy";
  const name = document.createElement("span");
  name.className = "row-title";
  name.textContent = title;
  const subtitle = document.createElement("span");
  subtitle.className = "row-detail";
  subtitle.textContent = detail;
  copy.append(name, subtitle);
  const actions = document.createElement("div");
  actions.className = "row-actions";
  li.append(copy, actions);
  return { li, actions };
}
function action(parent, title, run, quiet = false, disabled = false) {
  const button = document.createElement("button");
  button.textContent = title;
  button.disabled = disabled;
  if (quiet) button.className = "quiet danger";
  button.onclick = async () => {
    log2.info("action.requested", { action: title });
    button.disabled = true;
    busy++;
    try {
      await run();
    } catch (error) {
      failure(
        "notice-message",
        error,
        "Couldn\u2019t complete that action. Try again, or check Details."
      );
      $("notice").hidden = false;
    } finally {
      busy--;
      button.disabled = disabled;
      void refresh();
    }
  };
  parent.append(button);
}
async function openResult(resolve) {
  const tab = window.open("about:blank", "_blank");
  if (!tab)
    throw new Error("Allow pop-ups for SlopZooka to open a new window.");
  tab.opener = null;
  try {
    tab.location.replace(await resolve());
  } catch (error) {
    tab.close();
    throw error;
  }
}
function openFrontend(frontend) {
  return openResult(async () => {
    if (new URL(frontend.url).protocol === "https:") return frontend.url;
    const result = await api("/api/frontends/open", { id: frontend.id });
    const url = new URL(result.frontend.url);
    if (result.exposedPort) {
      url.protocol = "http:";
      url.hostname = location.hostname;
      url.port = String(result.exposedPort);
      url.pathname = "/__slz_access";
      url.search = "";
      url.hash = "";
      url.searchParams.set("token", result.accessToken);
    }
    return url.href;
  });
}
function workspaceFrontends(actions, workspaceId) {
  const frontends = data.frontends.filter(
    (f) => f.workspaceId === workspaceId && f.workspaceVisible !== false && f.category !== "service"
  );
  if (!frontends.length) return;
  if (frontends.length === 1) {
    const frontend = frontends[0];
    action(
      actions,
      "Open app",
      () => openFrontend(frontend),
      false,
      frontend.status === "stopped"
    );
    return;
  }
  const picker = document.createElement("select");
  picker.className = "button";
  picker.setAttribute("aria-label", "Open workspace frontend");
  const placeholder = new Option(`Frontends (${frontends.length})`, "");
  picker.append(placeholder);
  for (const frontend of frontends) {
    const option = new Option(
      `${frontend.title}${frontend.preferred ? " (default)" : ""}${frontend.status === "stopped" ? " \u2014 Stopped" : ""}`,
      frontend.id
    );
    option.disabled = frontend.status === "stopped";
    picker.append(option);
  }
  picker.onchange = () => {
    const frontend = frontends.find((f) => f.id === picker.value);
    picker.value = "";
    if (frontend)
      void openFrontend(frontend).catch(
        (error) => failure(
          `${section}-error`,
          error,
          "Couldn\u2019t open frontend. See Details."
        )
      );
  };
  actions.append(picker);
}
function render(key, force = false) {
  const query = $("filter");
  const term = key === section ? query.value.trim().toLowerCase() : "";
  const signature = JSON.stringify([
    data[key],
    term,
    key !== "frontends" ? data.frontends : null
  ]);
  if (!force && signatures.get(key) === signature) return;
  signatures.set(key, signature);
  const list = $(key);
  list.replaceChildren();
  const matches = (text) => text.toLowerCase().includes(term);
  if (key === "sessions")
    for (const s of data.sessions) {
      if (!matches(
        `${s.name ?? ""} ${s.title} ${s.projectName ?? ""} ${s.workspaceName ?? ""} ${s.cwd} ${s.status}`
      ))
        continue;
      const title = [s.projectName, s.workspaceName, s.name ?? s.title].filter(Boolean).join(" / ");
      const r = row(
        title,
        `${s.name ?? s.title} \xB7 ${s.status === "running" ? "Running" : "Ended"}`
      );
      r.li.title = s.cwd;
      const link = document.createElement("a");
      link.className = "button";
      link.textContent = "Open";
      link.href = `/terminal?sessionId=${encodeURIComponent(s.id)}`;
      link.target = "_blank";
      link.rel = "noopener";
      r.actions.append(link);
      workspaceFrontends(r.actions, s.workspaceId);
      action(
        r.actions,
        s.status === "running" ? "End" : "Remove",
        async () => {
          if (s.status === "running" && !confirm(
            `End ${s.name ?? s.title}? This stops the terminal and its running processes.`
          ))
            return;
          await api(
            `/api/sessions/${encodeURIComponent(s.id)}`,
            void 0,
            "DELETE"
          );
        },
        true
      );
      list.append(r.li);
    }
  if (key === "workspaces")
    for (const w of data.workspaces) {
      if (!matches(`${w.repo.nameWithOwner} ${w.name ?? ""} ${w.branchName}`))
        continue;
      const r = row(
        w.repo.nameWithOwner,
        w.existsOnDisk ? w.name ?? w.branchName : "Folder unavailable"
      );
      action(
        r.actions,
        "New shell",
        () => openResult(async () => {
          const { session } = await api(
            `/api/workspaces/${encodeURIComponent(w.workspaceId)}/sessions`,
            { sessionId: crypto.randomUUID(), profile: null }
          );
          return `/terminal?sessionId=${encodeURIComponent(session.id)}`;
        }),
        false,
        !w.existsOnDisk
      );
      workspaceFrontends(r.actions, w.workspaceId);
      list.append(r.li);
    }
  const services = document.createElement("ul");
  services.className = "rows";
  if (key === "frontends")
    for (const f of data.frontends) {
      if (!matches(`${f.title ?? ""} ${f.hostname} ${f.url} ${f.project ?? ""}`))
        continue;
      const statuses = {
        ready: "Ready",
        registered: "Available",
        starting: "Starting",
        stopped: "Stopped"
      };
      const r = row(
        f.title ?? f.hostname,
        `${f.project && f.source !== "local" ? f.project + " \xB7 " : ""}${f.title && f.title !== f.hostname ? f.hostname + " \xB7 " : ""}${statuses[f.status] ?? f.status}`
      );
      action(
        r.actions,
        "Open",
        () => openFrontend(f),
        false,
        f.status === "stopped"
      );
      if (f.source === "manual")
        action(
          r.actions,
          "Remove",
          async () => {
            await api(
              `/api/frontends/${encodeURIComponent(f.id)}`,
              void 0,
              "DELETE"
            );
          },
          true
        );
      (f.category === "service" ? services : list).append(r.li);
    }
  if (!list.children.length) {
    const hints = {
      sessions: "Open a workspace to start a shell, or launch an agent from Vision Pro.",
      workspaces: "Open a repository from Vision Pro to get started.",
      frontends: "Start a web app on your Mac or add a URL."
    };
    const empty = document.createElement("li");
    empty.className = "empty";
    const title = document.createElement("strong");
    title.textContent = term ? "No matches" : `No ${sections[key].toLowerCase()} yet`;
    empty.append(
      title,
      document.createTextNode(term ? "Try a different search." : hints[key])
    );
    list.append(empty);
  }
  if (services.children.length) {
    const group = document.createElement("li");
    group.className = "other-services";
    const details = document.createElement("details");
    details.open = showServices || !!term;
    details.ontoggle = () => {
      showServices = details.open;
    };
    const summary = document.createElement("summary");
    summary.textContent = `Other services (${services.children.length})`;
    details.append(summary, services);
    group.append(details);
    list.append(group);
  }
}
function navigate() {
  const hash = location.hash.slice(1);
  section = Object.hasOwn(sections, hash) ? hash : "sessions";
  log2.info("navigation.changed", { section });
  $("page-title").textContent = sections[section];
  $("add-url").hidden = section !== "frontends";
  const filter = $("filter");
  filter.value = "";
  filter.placeholder = `Filter ${sections[section].toLowerCase()}`;
  filter.setAttribute("aria-label", filter.placeholder);
  for (const key of Object.keys(sections)) {
    $(key + "-panel").hidden = key !== section;
    const link = document.querySelector(`[data-section="${key}"]`);
    if (key === section) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  render(section);
}
async function refresh() {
  if (!paired || refreshing || busy) return;
  refreshing = true;
  $("refresh").disabled = true;
  const keys = Object.keys(sections);
  const results = await Promise.allSettled(
    keys.map((key) => api(`/api/${key}`))
  );
  if (paired) {
    results.forEach((result, i) => {
      const key = keys[i];
      if (result.status === "fulfilled") {
        Object.assign(data, { [key]: result.value[key] });
        $(key + "-count").textContent = String(
          key === "frontends" ? data.frontends.filter((f) => f.category !== "service").length : data[key].length
        );
        message(key + "-error");
        if (key === "frontends")
          message("frontend-warning", result.value.warning ?? "");
        render(key);
      } else
        failure(
          key + "-error",
          result.reason,
          `Couldn\u2019t update ${sections[key].toLowerCase()}. Showing the last available list; retrying automatically.`
        );
    });
    render("sessions");
    render("workspaces");
    const healthy = results.every((result) => result.status === "fulfilled");
    connection(healthy ? "Connected to Mac" : "Reconnecting\u2026", healthy);
  }
  refreshing = false;
  $("refresh").disabled = false;
}
$("refresh").onclick = () => {
  log2.info("refresh.requested");
  void refresh();
};
$("dismiss-notice").onclick = () => {
  $("notice").hidden = true;
};
$("filter").oninput = () => render(section);
window.addEventListener("hashchange", navigate);
navigate();
$("pair").onsubmit = async (event) => {
  event.preventDefault();
  const button = document.querySelector("#pair button");
  button.disabled = true;
  try {
    await api("/api/pair", { code: $("code").value.trim() });
    message("pair-error");
    gate(true);
    await refresh();
  } catch (error) {
    failure(
      "pair-error",
      error,
      "Couldn\u2019t pair. Check the code in the Mac menu and try again."
    );
  } finally {
    button.disabled = false;
  }
};
var dialog = $("add-dialog");
$("add-url").onclick = () => {
  message("add-error");
  dialog.showModal();
  $("frontend-url").focus();
};
$("cancel-add").onclick = () => dialog.close();
$("add-frontend").onsubmit = async (event) => {
  event.preventDefault();
  const input = $("frontend-url");
  const buttons = dialog.querySelectorAll("button");
  buttons.forEach((b) => b.disabled = true);
  busy++;
  try {
    await api("/api/frontends", { url: input.value.trim() });
    input.value = "";
    dialog.close();
  } catch (error) {
    failure(
      "add-error",
      error,
      "Couldn\u2019t save this URL. Check the address and try again."
    );
  } finally {
    busy--;
    buttons.forEach((b) => b.disabled = false);
    void refresh();
  }
};
dialog.addEventListener("cancel", (event) => {
  if (busy) event.preventDefault();
});
async function connect() {
  if (dashboardTicket) {
    const ticket = dashboardTicket;
    dashboardTicket = null;
    try {
      await api("/api/pair/dashboard", { ticket });
    } catch (error) {
      gate(false);
      failure(
        "pair-error",
        error,
        "Open Dashboard again from the SlopZooka menu to sign in automatically."
      );
      return;
    }
  }
  try {
    const health = await api("/health");
    gate(health.paired);
    if (paired) await refresh();
  } catch (error) {
    connection("Mac unavailable");
    $("loading").hidden = false;
    failure(
      "loading",
      error,
      "Waiting for your Mac. Keep SlopZooka running in the menu bar; retrying automatically."
    );
  }
}
window.dispatchEvent(new Event("slz-dashboard-ready"));
void connect();
setInterval(() => {
  if (!document.hidden) {
    if (paired) void refresh();
    else if (!$("loading").hidden) void connect();
  }
}, 5e3);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && paired) void refresh();
});
