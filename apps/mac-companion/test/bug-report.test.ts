import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { once } from "node:events";
import express from "express";
import { Pairing } from "../src/auth.js";
import { createDiagnostics } from "../src/logger.js";
import {
  installDiagnosticsRoutes,
  logRequests,
} from "../src/diagnostics-http.js";
import { installBugReportRoutes } from "../src/bug-report-http.js";
import { GitHubClient } from "../src/github.js";
import { ServiceError } from "../src/errors.js";
import assert from "node:assert/strict";
import vm from "node:vm";
import { buildSync } from "esbuild";
import { fileURLToPath } from "node:url";
import { webcrypto } from "node:crypto";
import {
  bugReportBody,
  bugReportURL,
  type BugReportCapture,
} from "../src/bug-report-draft.js";

const capture: BugReportCapture = {
  reportId: "00000000-0000-0000-0000-000000000001",
  around: "2026-11-10T12:00:00.000Z",
  producers: [
    { source: "mac-companion", buildId: "a".repeat(64), runtimeId: "v22.20.0" },
    {
      source: "vision-client",
      buildId: "b".repeat(64),
      runtimeId: "os-26.1.0",
    },
  ],
  coverage: {
    truncated: false,
    unavailable: [],
    partialSegments: 0,
    malformedRecords: 0,
  },
};

test("public issue drafts use an explicit allowlist and never embed diagnostic contents or private attribution", () => {
  const privateCapture = {
    ...capture,
    hostId: "private-host",
    storage: { path: "/Users/private-user/private-project" },
    events: [
      {
        fields: {
          error: "private-error",
          url: "https://internal.invalid",
          token: "credential",
        },
      },
    ],
    producers: [
      ...capture.producers,
      {
        source: "browser" as const,
        instanceId: "private-instance",
        buildId: "private-build",
        runtimeId: "private-runtime",
      },
    ],
  };
  const body = bugReportBody(
    "Expected an open window, but it failed.",
    capture.around,
    privateCapture,
  );
  const url = new URL(bugReportURL("Window didn’t open", body));
  assert.equal(
    url.origin + url.pathname,
    "https://github.com/sragss/slopzooka/issues/new",
  );
  assert.equal(url.searchParams.get("title"), "Window didn’t open");
  assert.equal(url.searchParams.get("body"), body);
  for (const secret of [
    "private-host",
    "private-user",
    "private-project",
    "private-error",
    "internal.invalid",
    "credential",
    "private-instance",
    "private-build",
    "private-runtime",
  ])
    assert.ok(!body.includes(secret), secret);
  assert.ok(body.includes(capture.reportId));
  assert.ok(body.includes("logs have not been uploaded"));
  assert.ok(body.includes("a".repeat(64)) && body.includes("os-26.1.0"));
  assert.ok(
    bugReportBody("Description", capture.around, {
      ...capture,
      flushIncomplete: true,
    }).includes("incomplete coverage"),
  );
  assert.ok(
    bugReportBody("Description", capture.around).includes(
      "No diagnostic snapshot",
    ),
  );
  assert.throws(() => bugReportURL(" ", body), /summary/);
  assert.throws(() => bugReportURL("Summary", "🦄".repeat(4000)), /Shorten/);
});

const page = buildSync({
  entryPoints: [
    fileURLToPath(new URL("../src/bug-report.ts", import.meta.url)),
  ],
  bundle: true,
  platform: "browser",
  format: "iife",
  write: false,
  loader: { ".css": "empty" },
}).outputFiles[0]!.text;

async function fixture(status: number, withTicket = true) {
  const elements = new Map<string, any>();
  const make = () => ({
    value: "",
    hidden: true,
    textContent: "",
    href: "",
    name: "",
    removeAttribute(key: string) {
      delete (this as any)[key];
    },
    append(child: any) {
      this.children.push(child);
    },
    children: [] as any[],
  });
  for (const id of [
    "report-form",
    "description",
    "title",
    "download-report",
    "capture-status",
    "retry-capture",
    "public-preview",
    "report-error",
  ])
    elements.set(id, make());
  const location = new URL(
    `http://companion.invalid/report-bug?around=${encodeURIComponent(capture.around)}${withTicket ? "#connect=fixture-ticket" : ""}`,
  );
  const requests: { url: string; body: any }[] = [];
  vm.runInNewContext(page, {
    document: {
      getElementById: (id: string) => elements.get(id),
      createElement: make,
    },
    window: new EventTarget(),
    URL,
    URLSearchParams,
    TextEncoder,
    Headers,
    AbortSignal,
    performance,
    crypto: { getRandomValues: webcrypto.getRandomValues.bind(webcrypto) },
    location,
    history: {
      replaceState: (_a: unknown, _b: string, path: string) => {
        location.href = new URL(path, location).href;
      },
    },
    setInterval: () => 1,
    fetch: async (url: string, options: RequestInit) => {
      assert.equal(
        location.hash,
        "",
        "The browser ticket must be removed before any request",
      );
      requests.push({ url, body: JSON.parse(String(options.body)) });
      assert.ok(
        url.startsWith("/api/"),
        "Preparation never uploads to a third party",
      );
      return url === "/api/diagnostics/capture"
        ? new Response(JSON.stringify(capture), { status })
        : new Response("{}", { status: 200 });
    },
  });
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  return { elements, requests, location };
}

test("report page authenticates once, strips the ticket, saves locally, previews exactly the public form body, and links a protected download", async () => {
  const f = await fixture(200);
  assert.equal(f.location.search, "");
  assert.equal(f.requests[0]!.url, "/api/pair/dashboard");
  assert.equal(f.requests[0]!.body.ticket, "fixture-ticket");
  assert.deepEqual(
    f.requests.find((r) => r.url === "/api/diagnostics/capture")!.body,
    { around: capture.around },
  );
  assert.equal(f.elements.get("download-report").hidden, false);
  assert.equal(
    f.elements.get("download-report").href,
    `/api/diagnostics/reports/${capture.reportId}`,
  );
  f.elements.get("title").value = "A window failed";
  f.elements.get("description").value = "<script>plain user text</script>";
  const form = f.elements.get("report-form");
  form.oninput();
  let prevented = false;
  form.onsubmit({
    preventDefault: () => {
      prevented = true;
    },
  });
  assert.equal(
    prevented,
    false,
    "A normal browser GET opens GitHub's reviewable composer",
  );
  const body = form.children.find((child: any) => child.name === "body").value;
  assert.equal(body, f.elements.get("public-preview").textContent);
  assert.ok(
    body.includes("<script>plain user text</script>"),
    "Preview uses textContent, never HTML",
  );
  assert.ok(!body.includes("fixture-ticket"));
  assert.equal(
    f.requests.filter((r) => r.url === "/api/diagnostics/capture").length,
    1,
  );
});

test("snapshot failure preserves reporting, leaves no bogus download, and supports explicit local retry", async () => {
  for (const status of [401, 503]) {
    const f = await fixture(status, false);
    assert.equal(f.elements.get("download-report").hidden, true);
    assert.equal(f.elements.get("retry-capture").hidden, false);
    f.elements.get("title").value = "Still report this bug";
    f.elements.get("description").value = "The Mac could not connect.";
    let prevented = false;
    const form = f.elements.get("report-form");
    form.onsubmit({
      preventDefault: () => {
        prevented = true;
      },
    });
    assert.equal(prevented, false);
    assert.ok(form.children[0].value.includes("No diagnostic snapshot"));
    f.elements.get("retry-capture").onclick();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(
      f.requests.filter((r) => r.url === "/api/diagnostics/capture").length,
      2,
    );
  }
});

test("one native incident retains correlated evidence locally and publishes only the exact reviewed projection, once", async (t) => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), "slz-bug-report-"));
  const directory = path.join(home, "logs");
  const diagnostics = createDiagnostics("mac-companion", { directory });
  const app = express(),
    pairing = new Pairing(home);
  app.use(logRequests(diagnostics));
  app.use(express.json({ limit: "128kb" }));
  pairing.install(app);
  installDiagnosticsRoutes(app, diagnostics, pairing.hostId, async () => true);
  const published: { title: string; body: string }[] = [];
  let account: string | null = "reporter",
    fail = false;
  installBugReportRoutes(app, directory, {
    async bugReportAccount() {
      if (!account) throw new Error("No credentials");
      return account;
    },
    async createBugReport(title, body, expectedAccount) {
      if (account !== expectedAccount)
        throw new ServiceError("GitHub account changed", 409);
      published.push({ title, body });
      if (fail)
        throw new Error("A lost response may follow successful creation");
      return "https://github.com/sragss/slopzooka/issues/123";
    },
  });
  const server = http.createServer(app).listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await diagnostics.store.flush();
    await fs.rm(home, { recursive: true, force: true });
  });
  const base = `http://127.0.0.1:${(server.address() as import("node:net").AddressInfo).port}`;
  const post = (
    route: string,
    body: unknown,
    token?: string,
    origin?: string,
  ) =>
    fetch(base + route, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(origin ? { Origin: origin } : {}),
      },
      body: JSON.stringify(body),
    });
  const input = {
    title: "Window broke",
    description: "It vanished after reconnecting.",
    around: capture.around,
  };
  const prepare = "/api/diagnostics/bug-report/prepare",
    submit = "/api/diagnostics/bug-report/submit";
  assert.equal((await post(prepare, input)).status, 401);
  const paired = await post("/api/pair", { code: pairing.code });
  const { token } = (await paired.json()) as { token: string };
  assert.equal(
    (await post(prepare, input, token, "https://untrusted.invalid")).status,
    403,
  );
  assert.equal(
    (await post(prepare, { ...input, reportId: "../private-file" }, token))
      .status,
    400,
  );
  diagnostics.logger("window").info("window.failed", {
    actionId: "incident-action",
    path: "/Users/private/project",
    requestId: "incident-request",
  });
  const snapshot = await post(
    "/api/diagnostics/capture",
    { around: input.around },
    token,
  );
  assert.equal(snapshot.status, 200);
  const manifest = (await snapshot.json()) as BugReportCapture;
  const evidence = await fetch(
    `${base}/api/diagnostics/reports/${manifest.reportId}`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  const artifact = await evidence.text();
  assert.match(artifact, /incident-action/);
  assert.match(artifact, /incident-request/);
  assert.match(artifact, /private\/project/);
  assert.equal(
    (await fetch(`${base}/api/diagnostics/reports/${manifest.reportId}`))
      .status,
    401,
  );
  const response = await post(
    prepare,
    { ...input, reportId: manifest.reportId },
    token,
  );
  assert.equal(response.status, 200);
  const draft = (await response.json()) as {
    draftId: string;
    body: string;
    account: string;
    browserURL: string;
  };
  assert.equal(draft.account, "reporter");
  assert.equal(new URL(draft.browserURL).searchParams.get("body"), draft.body);
  assert.equal(
    draft.body,
    bugReportBody(input.description, input.around, manifest),
  );
  assert.ok(
    !draft.body.includes("private/project") &&
      !draft.body.includes("incident-action"),
  );
  assert.equal(
    published.length,
    0,
    "Preparing a public preview cannot post an issue",
  );
  const results = await Promise.all([
    post(
      submit,
      { draftId: draft.draftId, body: "unreviewed replacement" },
      token,
    ),
    post(submit, { draftId: draft.draftId }, token),
  ]);
  for (const result of results) assert.equal(result.status, 200);
  assert.deepEqual(published, [{ title: input.title, body: draft.body }]);
  account = "different-account";
  assert.equal(
    (await post(submit, { draftId: draft.draftId }, token)).status,
    200,
    "A changed account cannot hide an already-confirmed submission",
  );
  assert.equal(published.length, 1);
  const denied = (await (await post(prepare, input, token)).json()) as {
    draftId: string;
  };
  account = "another-account";
  for (let retry = 0; retry < 2; retry++)
    assert.equal(
      (await post(submit, { draftId: denied.draftId }, token)).status,
      409,
    );
  assert.equal(
    published.length,
    1,
    "An account mismatch never reaches GitHub's write API",
  );
  fail = true;
  const failed = (await (await post(prepare, input, token)).json()) as {
    draftId: string;
  };
  for (let retry = 0; retry < 2; retry++)
    assert.equal(
      (await post(submit, { draftId: failed.draftId }, token)).status,
      502,
    );
  assert.equal(
    published.length,
    2,
    "An uncertain result cannot blindly create duplicate public issues",
  );
  assert.equal((await post(submit, { draftId: "missing" }, token)).status, 410);
  account = null;
  const offline = (await (await post(prepare, input, token)).json()) as {
    account: null;
    browserURL: string;
    draftId: string;
  };
  assert.equal(offline.account, null);
  assert.equal(new URL(offline.browserURL).host, "github.com");
  assert.equal(
    (await post(submit, { draftId: offline.draftId }, token)).status,
    409,
  );
  assert.equal(published.length, 2);
  account = "reporter";
  fail = false;
  const expired = (await (await post(prepare, input, token)).json()) as {
    draftId: string;
  };
  const originalNow = Date.now;
  const later = originalNow() + 31 * 60_000;
  Date.now = () => later;
  try {
    assert.equal(
      (await post(submit, { draftId: expired.draftId }, token)).status,
      410,
    );
    assert.equal(
      published.length,
      2,
      "An expired review cannot create an issue",
    );
    const refreshed = (await (await post(prepare, input, token)).json()) as {
      draftId: string;
      body: string;
    };
    assert.notEqual(refreshed.draftId, expired.draftId);
    assert.equal(
      refreshed.body,
      bugReportBody(input.description, input.around),
    );
    assert.equal(
      (await post(submit, { draftId: refreshed.draftId }, token)).status,
      200,
    );
    assert.equal(
      published.length,
      3,
      "A fresh explicit review can publish after expiry",
    );
  } finally {
    Date.now = originalNow;
  }
  await diagnostics.store.flush();
  const log = await fs.readFile(
    path.join(directory, "mac-companion", "current.jsonl"),
    "utf8",
  );
  assert.ok(
    !log.includes(input.description) &&
      !log.includes(input.title) &&
      !log.includes(token),
    "Neither report text nor credentials belong in diagnostic events",
  );
});

test("host issue submission uses fixed GitHub API credentials without reflecting report text in failures", async () => {
  const originalFetch = globalThis.fetch,
    originalToken = process.env.GITHUB_TOKEN;
  process.env.GITHUB_TOKEN = "test-only-github-token";
  let ok = true;
  let writeStatus = 403;
  let viewer = "reporter";
  let viewerStatus = 200;
  const requests: { url: string; options: RequestInit }[] = [];
  globalThis.fetch = async (input, options) => {
    requests.push({ url: String(input), options: options! });
    if (String(input).endsWith("/graphql"))
      return new Response(
        JSON.stringify({ data: { viewer: { login: viewer } } }),
        { status: viewerStatus },
      );
    return new Response(
      ok
        ? JSON.stringify({
            html_url: "https://github.com/sragss/slopzooka/issues/123",
          })
        : "private submitted description",
      { status: ok ? 201 : writeStatus },
    );
  };
  try {
    const github = new GitHubClient();
    assert.equal(await github.bugReportAccount(), "reporter");
    assert.equal(
      await github.createBugReport(
        "Summary",
        "Reviewed public body",
        "reporter",
      ),
      "https://github.com/sragss/slopzooka/issues/123",
    );
    const request = requests.find((request) =>
      request.url.endsWith("/issues"),
    )!;
    assert.equal(
      request.url,
      "https://api.github.com/repos/sragss/slopzooka/issues",
    );
    assert.equal(
      new Headers(request.options.headers).get("Authorization"),
      "Bearer test-only-github-token",
    );
    assert.equal(request.options.redirect, "error");
    assert.deepEqual(JSON.parse(String(request.options.body)), {
      title: "Summary",
      body: "Reviewed public body",
    });
    viewer = "different-account";
    process.env.GITHUB_TOKEN = "refreshed-test-token";
    const writesBeforeRejection = requests.filter((request) =>
      request.url.endsWith("/issues"),
    ).length;
    await assert.rejects(
      github.createBugReport("Summary", "Reviewed body", "reporter"),
      (error) => error instanceof ServiceError && error.statusCode === 409,
    );
    assert.equal(
      requests.filter((request) => request.url.endsWith("/issues")).length,
      writesBeforeRejection,
    );
    assert.equal(await github.bugReportAccount(), "different-account");
    assert.equal(
      new Headers(requests.at(-1)!.options.headers).get("Authorization"),
      "Bearer refreshed-test-token",
    );
    viewer = "reporter";
    viewerStatus = 401;
    await assert.rejects(
      github.createBugReport("Summary", "Reviewed body", "reporter"),
      (error) => error instanceof ServiceError && error.statusCode === 409,
    );
    assert.equal(
      requests.filter((request) => request.url.endsWith("/issues")).length,
      writesBeforeRejection,
    );
    viewerStatus = 200;
    ok = false;
    for (const status of [401, 403]) {
      writeStatus = status;
      await assert.rejects(
        github.createBugReport(
          "Summary",
          "private submitted description",
          "reporter",
        ),
        (error) =>
          error instanceof ServiceError &&
          error.statusCode === 409 &&
          !error.message.includes("private submitted description"),
      );
    }
    writeStatus = 503;
    await assert.rejects(
      github.createBugReport(
        "Summary",
        "private submitted description",
        "reporter",
      ),
      /^Error: GitHub issue request returned HTTP 503$/,
    );
  } finally {
    globalThis.fetch = originalFetch;
    if (originalToken === undefined) delete process.env.GITHUB_TOKEN;
    else process.env.GITHUB_TOKEN = originalToken;
  }
});

test("a CLI account refresh during preflight cannot change the reviewed issue's author", async () => {
  const originalFetch = globalThis.fetch,
    originalToken = process.env.GITHUB_TOKEN;
  let releaseViewer!: () => void, viewerStarted!: () => void;
  const release = new Promise<void>((resolve) => {
    releaseViewer = resolve;
  });
  const started = new Promise<void>((resolve) => {
    viewerStarted = resolve;
  });
  let issue: Promise<string> | undefined;
  const writes: string[] = [];
  globalThis.fetch = async (input, options) => {
    const authorization = new Headers(options?.headers).get("Authorization")!;
    if (String(input).endsWith("/graphql")) {
      const login =
        authorization === "Bearer first-test-token"
          ? "first-user"
          : "second-user";
      if (login === "first-user") {
        viewerStarted();
        await release;
      }
      return new Response(JSON.stringify({ data: { viewer: { login } } }));
    }
    writes.push(authorization);
    return new Response(
      JSON.stringify({
        html_url: "https://github.com/sragss/slopzooka/issues/123",
      }),
      { status: 201 },
    );
  };
  try {
    const github = new GitHubClient();
    process.env.GITHUB_TOKEN = "first-test-token";
    issue = github.createBugReport(
      "Reviewed summary",
      "Reviewed body",
      "first-user",
    );
    await Promise.race([
      started,
      issue.then(() => {
        throw new Error("Issue creation finished before the account preflight");
      }),
    ]);
    process.env.GITHUB_TOKEN = "second-test-token";
    assert.equal(await github.bugReportAccount(), "second-user");
    releaseViewer();
    await issue;
    assert.deepEqual(writes, ["Bearer first-test-token"]);
  } finally {
    releaseViewer();
    await issue?.catch(() => undefined);
    globalThis.fetch = originalFetch;
    if (originalToken === undefined) delete process.env.GITHUB_TOKEN;
    else process.env.GITHUB_TOKEN = originalToken;
  }
});
