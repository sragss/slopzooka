import type { SessionSummary } from "../../../packages/protocol/src/index.js";
const status = document.querySelector<HTMLElement>("#status")!;
async function api(
  path: string,
  body?: unknown,
  method = body ? "POST" : "GET",
) {
  const response = await fetch(path, {
    method,
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error ?? `HTTP ${response.status}`);
  return result;
}
function item(
  list: Element,
  label: string,
  actions: Array<[string, () => Promise<void> | void]>,
) {
  const li = document.createElement("li");
  li.append(document.createTextNode(label));
  for (const [name, action] of actions) {
    const button = document.createElement("button");
    button.textContent = name;
    button.onclick = () => {
      Promise.resolve(action()).catch((error) => {
        status.textContent = error.message;
      });
    };
    li.append(button);
  }
  list.append(li);
}
async function refresh() {
  const [sessions, workspaces, catalog] = await Promise.all([
    api("/api/sessions"),
    api("/api/workspaces"),
    api("/api/frontends"),
  ]);
  for (const name of ["sessions", "workspaces", "frontends"])
    document.querySelector(`#${name}`)!.replaceChildren();
  for (const s of sessions.sessions as SessionSummary[])
    item(
      document.querySelector("#sessions")!,
      `${s.title} • ${s.cwd} • ${s.status}`,
      [
        [
          "Open",
          () => {
            window.open(
              `/terminal?sessionId=${encodeURIComponent(s.id)}`,
              "_blank",
            );
          },
        ],
        [
          s.status === "running" ? "End session" : "Remove",
          async () => {
            await api(`/api/sessions/${s.id}`, undefined, "DELETE");
            await refresh();
          },
        ],
      ],
    );
  for (const w of workspaces.workspaces)
    item(document.querySelector("#workspaces")!, w.repo.nameWithOwner, [
      [
        "New shell",
        async () => {
          const { session } = await api(
            `/api/workspaces/${w.workspaceId}/sessions`,
            { sessionId: crypto.randomUUID(), profile: null },
          );
          window.open(`/terminal?sessionId=${session.id}`, "_blank");
          await refresh();
        },
      ],
    ]);
  for (const f of catalog.frontends)
    item(
      document.querySelector("#frontends")!,
      `${f.title ?? f.hostname} • ${f.status}`,
      [
        [
          "Open",
          async () => {
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
            window.open(url, "_blank");
          },
        ],
        ...(f.source === "manual"
          ? [
              [
                "Remove",
                async () => {
                  await api(
                    `/api/frontends/${encodeURIComponent(f.id)}`,
                    undefined,
                    "DELETE",
                  );
                  await refresh();
                },
              ] as [string, () => Promise<void>],
            ]
          : []),
      ],
    );
  status.textContent = catalog.warning ?? "Connected";
}
document.querySelector<HTMLFormElement>("#pair")!.onsubmit = (event) => {
  event.preventDefault();
  void api("/api/pair", {
    code: document.querySelector<HTMLInputElement>("#code")!.value.trim(),
  })
    .then(() => refresh())
    .catch((error) => {
      status.textContent = error.message;
    });
};
void refresh().catch((error) => {
  status.textContent = error.message;
});
setInterval(() => {
  if (!document.hidden)
    void refresh().catch((error) => {
      status.textContent = error.message;
    });
}, 5000);

document.querySelector<HTMLFormElement>("#add-frontend")!.onsubmit = (
  event,
) => {
  event.preventDefault();
  const input = document.querySelector<HTMLInputElement>("#frontend-url")!;
  void api("/api/frontends", { url: input.value.trim() })
    .then(async () => {
      input.value = "";
      await refresh();
    })
    .catch((error) => {
      status.textContent = error.message;
    });
};
