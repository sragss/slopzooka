// Opt-in end-to-end smoke: real HTTP companion, Pi, retained worker service and Codex.
// Uses an isolated home and fixture workspace; never connects to the installed companion.
import fs from "node:fs/promises";
import path from "node:path";
import net from "node:net";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import { SessionServiceClient } from "../../apps/mac-companion/src/session-service-client.js";
const root = path.resolve(import.meta.dirname, "../..");
const fixtureApp = process.env.SLZ_COORDINATOR_FIXTURE;
const fixtureState = process.env.SLZ_COORDINATOR_FIXTURE_STATE;
const bundle = process.env.SLZ_COORDINATOR_MAC;
const requireHost = createRequire(
  path.join(root, "apps/mac-companion/package.json"),
);
const { WebSocket } = requireHost("ws");
const { Terminal } = requireHost("@xterm/headless");
const run = await fs.mkdtemp("/tmp/slz-coordinator-smoke-");
await fs.chmod(run, 0o700);
const home = path.join(run, "home"),
  cwd = path.join(run, "workspace");
await fs.mkdir(cwd, { recursive: true });
await fs.mkdir(path.join(home, "workspaces"), { recursive: true });
await fs.writeFile(
  path.join(cwd, "README.md"),
  "Disposable coordinator fixture. The verification word is ORCHID. Do not edit files.\n" +
    (fixtureApp
      ? `Use native computer control to open the exact app path ${JSON.stringify(fixtureApp)}, click Increment exactly twice and enter coordinator-native in Probe input. Access only this fixture. Take a screenshot after observing the result. No shell-based UI automation or fixture-state edits. If native control is unavailable report it and stop. Then report ORCHID and the observed counter/input.\n`
      : ""),
);
const now = new Date().toISOString();
await fs.writeFile(
  path.join(home, "workspaces/index.json"),
  JSON.stringify([
    {
      workspaceId: "coordinator-fixture",
      name: "Coordinator fixture",
      repo: {
        name: "coordinator-fixture",
        nameWithOwner: "slopzooka/coordinator-fixture",
        url: "https://github.com/slopzooka/coordinator-fixture",
        sshUrl: "git@github.com:slopzooka/coordinator-fixture.git",
        pushedAt: now,
        isPrivate: true,
        defaultBranch: "main",
        owner: { login: "slopzooka", name: null, avatarUrl: "" },
      },
      profile: "codex",
      localCheckoutPath: cwd,
      worktreePath: cwd,
      branchName: "fixture",
      baseRef: "main",
      createdAt: now,
      updatedAt: now,
    },
  ]),
);
const listener = net.createServer();
await new Promise<void>((r) => listener.listen(0, "127.0.0.1", r));
const port = (listener.address() as net.AddressInfo).port;
await new Promise<void>((r) => listener.close(() => r()));
const origin = `http://127.0.0.1:${port}`;
const child = spawn(
  bundle
    ? path.join(bundle, "Contents/Resources/runtime/node")
    : process.execPath,
  bundle
    ? [path.join(bundle, "Contents/Resources/host/src/server.mjs")]
    : [
        path.join(root, "apps/mac-companion/node_modules/tsx/dist/cli.mjs"),
        path.join(root, "apps/mac-companion/src/server.ts"),
      ],
  {
    cwd: root,
    env: {
      ...process.env,
      SLOPZOOKA_HOME: home,
      SLOPZOOKA_PORT: String(port),
      SLOPZOOKA_HOST: "127.0.0.1",
      SLOPZOOKA_PORTLESS: "0",
      SLOPZOOKA_DIRECT: "0",
      SLOPZOOKA_COORDINATOR_CONFIG:
        process.env.SLOPZOOKA_COORDINATOR_CONFIG ??
        path.join(
          process.env.HOME!,
          ".slopzooka/coordinator-development/config.json",
        ),
    },
    stdio: ["ignore", "pipe", "pipe"],
  },
);
let output = "";
child.stdout.on("data", (b) => {
  output += b;
});
child.stderr.on("data", (b) => {
  void fs.appendFile(path.join(run, "companion.stderr.log"), b);
});
const until = async <T,>(
  fn: () => Promise<T | undefined>,
  label: string,
  ms = 120000,
): Promise<T> => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error("Timeout: " + label);
};
const clientId = randomUUID();
let headers: Record<string, string>;
const api = async (route: string, body?: unknown) => {
  const r = await fetch(origin + route, {
    method: body === undefined ? "GET" : "POST",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!r.ok) throw new Error(route + " HTTP " + r.status);
  return r.json();
};
try {
  await until(
    async () => {
      try {
        return (await fetch(origin + "/health")).ok || undefined;
      } catch {
        return undefined;
      }
    },
    "companion health",
    20000,
  );
  const code = output.match(/pairing code: (\d{6})/)?.[1];
  if (!code) throw new Error("No pairing code");
  const pair = await fetch(origin + "/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code }),
  }).then((r) => r.json());
  headers = {
    Authorization: "Bearer " + pair.token,
    "X-SlopZooka-Client-ID": clientId,
    "Content-Type": "application/json",
  };
  const request = {
    requestId: randomUUID(),
    text:
      "Use the existing Coordinator fixture workspace. Start one real Codex worker there and ask it to read README.md, " +
      (fixtureApp ? "perform its authorized native fixture test and " : "") +
      "report the verification word without editing files. Do not create a new worktree. Present its terminal if the headset is available. Report if it is offline.",
  };
  const accepted = await api("/api/coordinator", request);
  console.log("Accepted", accepted.status);
  const done = await until(
    async () => {
      const s = await api("/api/coordinator");
      return s.status !== "running" ? s : undefined;
    },
    "Pi request",
    150000,
  );
  console.log("Pi", done.status, done.reply);
  const worker = await until(
    async () => {
      const s = await api("/api/coordinator");
      const w = s.workers[0];
      return ["completed", "failed", "interrupted"].includes(w?.status)
        ? w
        : undefined;
    },
    "worker result",
    90000,
  );
  console.log("Worker", worker.status, worker.result);
  if (worker.status !== "completed" || !worker.result?.includes("ORCHID"))
    throw new Error("Worker did not read fixture");
  if (fixtureApp) {
    if (!fixtureState)
      throw new Error("Native test needs SLZ_COORDINATOR_FIXTURE_STATE");
    const observation = JSON.parse(await fs.readFile(fixtureState, "utf8"));
    if (observation.counter !== 2 || observation.text !== "coordinator-native")
      throw new Error("Independent fixture state disagrees with worker");
    await fs.writeFile(
      path.join(run, "fixture-observation.json"),
      JSON.stringify(observation),
    );
  }
  // Read actual PTY replay, not just the model backend's claimed response.
  const socket = new WebSocket(origin.replace("http:", "ws:") + "/ws", {
    headers,
  });
  const terminal = new Terminal({
    cols: 120,
    rows: 40,
    allowProposedApi: true,
  });
  socket.on("message", (raw: Buffer) => {
    const message = JSON.parse(raw.toString());
    if (message.type === "hello") {
      socket.send(
        JSON.stringify({ type: "attach", sessionId: worker.sessionId }),
      );
      socket.send(
        JSON.stringify({
          type: "resize",
          sessionId: worker.sessionId,
          cols: 120,
          rows: 40,
        }),
      );
    }
    if (message.type === "attached" || message.type === "output") {
      terminal.write(message.snapshot ?? message.data ?? "");
      socket.send(
        JSON.stringify({
          type: "ack",
          sessionId: worker.sessionId,
          cursor: message.cursor,
        }),
      );
    }
  });
  try {
    await until(
      async () => {
        const buffer = terminal.buffer.active;
        const text = Array.from(
          { length: buffer.length },
          (_, i) => buffer.getLine(i)?.translateToString(true) ?? "",
        ).join("\n");
        await fs.writeFile(path.join(run, "terminal.txt"), text, {
          mode: 0o600,
        });
        return text.includes("ORCHID") ? true : undefined;
      },
      "real TUI rendered worker result",
      15000,
    );
  } finally {
    socket.terminate();
    terminal.dispose();
  }
  const followup = {
    requestId: randomUUID(),
    text: "Use this same worker. Check headset preview availability through its slopzooka-previews MCP, report accurately whether it is available, and reply with FOLLOWUP-ORCHID. Do not open previews or change any files or apps.",
    sessionId: worker.sessionId,
    workspaceId: "coordinator-fixture",
  };
  await api("/api/coordinator", followup);
  const followed = await until(
    async () => {
      const status = await api("/api/coordinator");
      const next = status.workers.find(
        (w: any) => w.sessionId === worker.sessionId,
      );
      if (next?.question)
        throw new Error("Worker needs approval: " + next.question.title);
      return next?.status === "completed" &&
        next.result?.includes("FOLLOWUP-ORCHID")
        ? next
        : undefined;
    },
    "queued follow-up on the same real worker",
    90000,
  );
  if (followed.threadId !== worker.threadId)
    throw new Error("Follow-up changed worker thread");
  console.log("Follow-up", followed.status, followed.result);
  const repeated = await api("/api/coordinator", request);
  if (repeated.workers.length !== 1) throw new Error("Duplicate worker");
  const service = await SessionServiceClient.forHome(home);
  const info = await service.info();
  if (info.sessions.length !== 1) throw new Error("Expected one PTY");
  await fs.writeFile(
    path.join(run, "results.json"),
    JSON.stringify(
      { accepted, done, worker, followed, sessionCount: info.sessions.length },
      null,
      2,
    ),
    { mode: 0o600 },
  );
  console.log(
    "PASS: real Pi -> session-owned Codex -> fixture result; repeated request retained one worker; evidence",
    run,
  );
} finally {
  const closed = once(child, "exit");
  child.kill("SIGTERM");
  if (child.exitCode === null) await closed;
  const service = await SessionServiceClient.forHome(home);
  await service.stop().catch(() => {});
}
