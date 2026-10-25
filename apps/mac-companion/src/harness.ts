import "./dashboard.css";
import type { SessionSummary } from "../../../packages/protocol/src/index.js";
import type { Frontend } from "./frontend-discovery.js";

type Workspace = {
  workspaceId: string;
  repo: { nameWithOwner: string };
  branchName: string;
  existsOnDisk: boolean;
};
const sections = {
  sessions: "Terminals",
  workspaces: "Workspaces",
  frontends: "Frontends",
};
type Section = keyof typeof sections;
const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;
let section: Section = "sessions";
let paired = false;
let refreshing = false;
let busy = 0;
const data: {
  sessions: SessionSummary[];
  workspaces: Workspace[];
  frontends: Frontend[];
} = { sessions: [], workspaces: [], frontends: [] };
const signatures = new Map<Section, string>();
let showServices = false;
function message(id: string, text = "") {
  delete $(id).dataset.detail;
  $(id).textContent = text;
  $(id).hidden = !text;
}
function failure(id: string, error: unknown, guidance: string) {
  const detail =
    error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  const element = $(id);
  // Preserve expanded details across polling failures, without discarding the actual error.
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
function connection(text: string, connected = false) {
  $("connection-label").textContent = text;
  document.body.dataset.connected = String(connected);
}
function gate(authorized: boolean) {
  paired = authorized;
  $("loading").hidden = true;
  $("pairing").hidden = authorized;
  $("dashboard").hidden = !authorized;
  if (!authorized) {
    $<HTMLDialogElement>("add-dialog").close();
    connection("Pairing required");
    for (const key of Object.keys(sections)) $(key + "-count").textContent = "";
  }
}
async function api(
  path: string,
  body?: unknown,
  method = body ? "POST" : "GET",
) {
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      signal: AbortSignal.timeout(30_000),
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (error) {
    throw new Error(
      `${method} ${path}: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    );
  }
  if (response.status === 401) gate(false);
  const text = await response.text();
  let result;
  try {
    result = JSON.parse(text);
  } catch (error) {
    throw new Error(
      `${method} ${path} — HTTP ${response.status}: Invalid JSON response. ${String(error)}\n${text.slice(0, 2048)}`,
      { cause: error },
    );
  }
  if (!response.ok)
    throw new Error(
      `${method} ${path} — HTTP ${response.status}: ${result.error ?? response.statusText}`,
    );
  return result;
}
function row(title: string, detail: string) {
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
function action(
  parent: HTMLElement,
  title: string,
  run: () => Promise<void>,
  quiet = false,
  disabled = false,
) {
  const button = document.createElement("button");
  button.textContent = title;
  button.disabled = disabled;
  if (quiet) button.className = "quiet danger";
  button.onclick = async () => {
    button.disabled = true;
    busy++;
    try {
      await run();
    } catch (error) {
      failure(
        "notice-message",
        error,
        "Couldn’t complete that action. Try again, or check Details.",
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
// Reserve the new tab during the click, before awaiting network requests.
async function openResult(resolve: () => Promise<string>) {
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
function render(key: Section, force = false) {
  const query = $("filter") as HTMLInputElement;
  const term = key === section ? query.value.trim().toLowerCase() : "";
  const signature = JSON.stringify([data[key], term]);
  if (!force && signatures.get(key) === signature) return;
  signatures.set(key, signature);
  const list = $(key);
  list.replaceChildren();
  const matches = (text: string) => text.toLowerCase().includes(term);
  if (key === "sessions")
    for (const s of data.sessions) {
      if (!matches(`${s.title} ${s.cwd} ${s.status}`)) continue;
      const title = s.cwd.split("/").filter(Boolean).pop() || s.title;
      const r = row(
        title,
        `${s.title} · ${s.status === "running" ? "Running" : "Ended"}`,
      );
      r.li.title = s.cwd;
      const link = document.createElement("a");
      link.className = "button";
      link.textContent = "Open";
      link.href = `/terminal?sessionId=${encodeURIComponent(s.id)}`;
      link.target = "_blank";
      link.rel = "noopener";
      r.actions.append(link);
      action(
        r.actions,
        s.status === "running" ? "End" : "Remove",
        async () => {
          if (
            s.status === "running" &&
            !confirm(
              `End ${s.title}? This stops the terminal and its running processes.`,
            )
          )
            return;
          await api(
            `/api/sessions/${encodeURIComponent(s.id)}`,
            undefined,
            "DELETE",
          );
        },
        true,
      );
      list.append(r.li);
    }
  if (key === "workspaces")
    for (const w of data.workspaces) {
      if (!matches(`${w.repo.nameWithOwner} ${w.branchName}`)) continue;
      const r = row(
        w.repo.nameWithOwner,
        w.existsOnDisk ? w.branchName : "Folder unavailable",
      );
      action(
        r.actions,
        "New shell",
        () =>
          openResult(async () => {
            const { session } = await api(
              `/api/workspaces/${encodeURIComponent(w.workspaceId)}/sessions`,
              { sessionId: crypto.randomUUID(), profile: null },
            );
            return `/terminal?sessionId=${encodeURIComponent(session.id)}`;
          }),
        false,
        !w.existsOnDisk,
      );
      list.append(r.li);
    }
  const services = document.createElement("ul");
  services.className = "rows";
  if (key === "frontends")
    for (const f of data.frontends) {
      if (
        !matches(`${f.title ?? ""} ${f.hostname} ${f.url} ${f.project ?? ""}`)
      )
        continue;
      const statuses = {
        ready: "Ready",
        registered: "Available",
        starting: "Starting",
        stopped: "Stopped",
      };
      const r = row(
        f.title ?? f.hostname,
        `${f.project && f.source !== "local" ? f.project + " · " : ""}${f.title && f.title !== f.hostname ? f.hostname + " · " : ""}${statuses[f.status] ?? f.status}`,
      );
      action(
        r.actions,
        "Open",
        () =>
          openResult(async () => {
            const result = await api("/api/frontends/open", { id: f.id });
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
          }),
        false,
        f.status === "stopped",
      );
      if (f.source === "manual")
        action(
          r.actions,
          "Remove",
          async () => {
            await api(
              `/api/frontends/${encodeURIComponent(f.id)}`,
              undefined,
              "DELETE",
            );
          },
          true,
        );
      (f.category === "service" ? services : list).append(r.li);
    }
  if (!list.children.length) {
    const hints = {
      sessions:
        "Open a workspace to start a shell, or launch an agent from Vision Pro.",
      workspaces: "Open a repository from Vision Pro to get started.",
      frontends: "Start a web app on your Mac or add a URL.",
    };
    const empty = document.createElement("li");
    empty.className = "empty";
    const title = document.createElement("strong");
    title.textContent = term
      ? "No matches"
      : `No ${sections[key].toLowerCase()} yet`;
    empty.append(
      title,
      document.createTextNode(term ? "Try a different search." : hints[key]),
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
  section = Object.hasOwn(sections, hash) ? (hash as Section) : "sessions";
  $("page-title").textContent = sections[section];
  $("add-url").hidden = section !== "frontends";
  const filter = $<HTMLInputElement>("filter");
  filter.value = "";
  filter.placeholder = `Filter ${sections[section].toLowerCase()}`;
  filter.setAttribute("aria-label", filter.placeholder);
  for (const key of Object.keys(sections) as Section[]) {
    $(key + "-panel").hidden = key !== section;
    const link = document.querySelector(`[data-section="${key}"]`)!;
    if (key === section) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  render(section);
}
async function refresh() {
  if (!paired || refreshing || busy) return;
  refreshing = true;
  $<HTMLButtonElement>("refresh").disabled = true;
  const keys = Object.keys(sections) as Section[];
  const results = await Promise.allSettled(
    keys.map((key) => api(`/api/${key}`)),
  );
  if (paired) {
    results.forEach((result, i) => {
      const key = keys[i]!;
      if (result.status === "fulfilled") {
        Object.assign(data, { [key]: result.value[key] });
        $(key + "-count").textContent = String(
          key === "frontends"
            ? data.frontends.filter((f) => f.category !== "service").length
            : data[key].length,
        );
        message(key + "-error");
        if (key === "frontends")
          message("frontend-warning", result.value.warning ?? "");
        render(key);
      } else
        failure(
          key + "-error",
          result.reason,
          `Couldn’t update ${sections[key].toLowerCase()}. Showing the last available list; retrying automatically.`,
        );
    });
    const healthy = results.every((result) => result.status === "fulfilled");
    connection(healthy ? "Connected to Mac" : "Reconnecting…", healthy);
  }
  refreshing = false;
  $<HTMLButtonElement>("refresh").disabled = false;
}
$("refresh").onclick = () => void refresh();
$("dismiss-notice").onclick = () => {
  $("notice").hidden = true;
};
$("filter").oninput = () => render(section);
window.addEventListener("hashchange", navigate);
navigate();
$<HTMLFormElement>("pair").onsubmit = async (event) => {
  event.preventDefault();
  const button = document.querySelector<HTMLButtonElement>("#pair button")!;
  button.disabled = true;
  try {
    await api("/api/pair", { code: $<HTMLInputElement>("code").value.trim() });
    message("pair-error");
    gate(true);
    await refresh();
  } catch (error) {
    failure(
      "pair-error",
      error,
      "Couldn’t pair. Check the code in the Mac menu and try again.",
    );
  } finally {
    button.disabled = false;
  }
};
const dialog = $<HTMLDialogElement>("add-dialog");
$("add-url").onclick = () => {
  message("add-error");
  dialog.showModal();
  $("frontend-url").focus();
};
$("cancel-add").onclick = () => dialog.close();
$<HTMLFormElement>("add-frontend").onsubmit = async (event) => {
  event.preventDefault();
  const input = $<HTMLInputElement>("frontend-url");
  const buttons = dialog.querySelectorAll("button");
  buttons.forEach((b) => (b.disabled = true));
  busy++;
  try {
    await api("/api/frontends", { url: input.value.trim() });
    input.value = "";
    dialog.close();
  } catch (error) {
    failure(
      "add-error",
      error,
      "Couldn’t save this URL. Check the address and try again.",
    );
  } finally {
    busy--;
    buttons.forEach((b) => (b.disabled = false));
    void refresh();
  }
};
dialog.addEventListener("cancel", (event) => {
  if (busy) event.preventDefault();
});
async function connect() {
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
      "Waiting for your Mac. Keep SlopZooka running in the menu bar; retrying automatically.",
    );
  }
}
void connect();
setInterval(() => {
  if (!document.hidden) {
    if (paired) void refresh();
    else if (!$("loading").hidden) void connect();
  }
}, 5000);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && paired) void refresh();
});
