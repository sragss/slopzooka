import assert from "node:assert/strict";
import { spawn, execFileSync, execFile } from "node:child_process";
import { createRequire } from "node:module";
import {
  mkdir,
  mkdtemp,
  readFile,
  writeFile,
  copyFile,
  chmod,
  rm,
  access,
  appendFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import { SessionServiceClient } from "../../apps/mac-companion/src/session-service-client.js";
import { Rpc } from "./rpc.mjs";
const require = createRequire(
  new URL("../../apps/mac-companion/package.json", import.meta.url),
);
const { WebSocket } = require("ws");
const root = dirname(fileURLToPath(import.meta.url));
const codex = process.argv[2];
if (!codex || !codex.startsWith("/"))
  throw new Error("Pass an explicit absolute Codex executable");
await mkdir(join(root, "build"), { recursive: true });
const run = await mkdtemp(join(root, "build", "run-"));
await chmod(run, 0o700);
const privateDir = await mkdtemp(join(tmpdir(), "slz-worker-"));
await chmod(privateDir, 0o700);
const home = join(privateDir, "codex"),
  cwd = join(privateDir, "workspace"),
  socket = join(privateDir, "codex.sock");
await mkdir(home);
await mkdir(cwd);
const env: Record<string, string> = Object.fromEntries(
  ["HOME", "PATH", "TMPDIR", "LANG", "USER", "LOGNAME"]
    .filter((k) => process.env[k])
    .map((k) => [k, process.env[k]!]),
);
env.CODEX_HOME = home;
env.ZDOTDIR = privateDir;
env.SHELL = "/bin/zsh";
const report: any = {
  startedAt: new Date().toISOString(),
  version: execFileSync(codex, ["--version"], { encoding: "utf8" }).trim(),
  run,
  checks: {},
};
const save = () =>
  writeFile(join(run, "results.json"), JSON.stringify(report, null, 2), {
    mode: 0o600,
  });
const status = async (stage, value = {}) => {
  console.log(JSON.stringify({ stage, ...value }));
  await save();
};
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, description, ms = 60000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const x = await fn();
    if (x) return x;
    await pause(50);
  }
  throw new Error(`Timed out: ${description}`);
}
const entries = async () => {
  try {
    return (await readFile(join(run, "fixture.jsonl"), "utf8"))
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse);
  } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
};
const effect = (label) =>
  until(
    async () =>
      (await entries()).find((x) => x.event === "effect" && x.label === label),
    `effect ${label}`,
  );
const gate = (label) =>
  until(
    async () =>
      (await entries()).find(
        (x) =>
          x.event === "entered" && x.tool === "wait_gate" && x.label === label,
      ),
    `gate ${label}`,
  );
const release = (label) =>
  writeFile(join(run, `release-${label}`), "released\n");
const input = (text) => [{ type: "text", text }];
const prompt = (text) =>
  `User-authorized disposable worker-delivery test. Use only delivery_fixture MCP tools. Do not use shell, other files, internet, other agents or other tools. ${text}`;
const quote = (s) => "'" + s.replaceAll("'", "'\\''") + "'";
let service: SessionServiceClient,
  backend,
  backendDone,
  rpc: Rpc,
  viewer,
  sessionID = randomUUID(),
  threadID: string,
  viewerOutput = "";
const rpcs = [];
async function connect(label) {
  const client = new Rpc(codex, socket, env, join(run, `${label}-rpc.jsonl`));
  rpcs.push(client);
  await client.initialize();
  return client;
}
async function completed(client, turnID) {
  return until(
    () =>
      client.events.find(
        (e) => e.method === "turn/completed" && e.params.turn.id === turnID,
      ),
    `turn completion ${turnID}`,
  );
}
async function queue(label, text, client = rpc) {
  const id = randomUUID();
  const response = await client.call("thread/queue/add", {
    threadId: threadID,
    clientUserMessageId: id,
    input: input(prompt(text)),
  });
  return { id, ...response };
}
try {
  // Reuse normal ChatGPT login without printing or committing credentials. Only
  // this private copy can be refreshed; it is removed in finally.
  await copyFile(
    join(process.env.HOME!, ".codex", "auth.json"),
    join(home, "auth.json"),
  );
  await chmod(join(home, "auth.json"), 0o600);
  const cfg = `model = "gpt-6.1-sol"\nmodel_reasoning_effort = "low"\ncli_auth_credentials_store = "file"\napproval_policy = "on-request"\nsandbox_mode = "read-only"\nweb_search = "disabled"\n[features]\napps = false\nplugins = false\nshell_tool = false\n[projects.${JSON.stringify(cwd)}]\ntrust_level = "trusted"\n[mcp_servers.delivery_fixture]\ncommand = ${JSON.stringify(process.execPath)}\nargs = ${JSON.stringify([join(root, "fixture.mjs"), run])}\nrequired = true\ndefault_tools_approval_mode = "approve"\ntool_timeout_sec = 150\n`;
  await writeFile(join(home, "config.toml"), cfg, { mode: 0o600 });
  backend = spawn(codex, ["app-server", "--listen", `unix://${socket}`], {
    env,
    cwd,
    stdio: ["ignore", "pipe", "pipe"],
  });
  backendDone = new Promise((r) =>
    backend.once("exit", (code, signal) => r({ code, signal })),
  );
  for (const stream of [backend.stdout, backend.stderr])
    stream.on("data", (x) =>
      appendFile(join(run, "backend.log"), x, { mode: 0o600 }),
    );
  await until(
    async () => {
      try {
        await access(socket);
        return true;
      } catch {
        return false;
      }
    },
    "owned backend socket",
    20000,
  );
  service = await SessionServiceClient.forHome(join(privateDir, "slz"));
  const info = await service.connectOrStart();
  env.SLOPZOOKA_CODEX_COMMAND =
    [codex, "--remote", `unix://${socket}`, "--no-alt-screen", "-C", cwd]
      .map(quote)
      .join(" ") + "; printf 'SLZ_AGENT_EXITED\\n'";
  const summary = await service.create({
    workspaceId: "worker-delivery-fixture",
    cwd,
    profile: "codex",
    id: sessionID,
    environment: env,
  });
  report.session = {
    summary,
    servicePID: info.pid,
    serviceInstance: info.instanceId,
    backendPID: backend.pid,
  };
  viewer = new WebSocket(`ws+unix://${service.socketPath}:/terminal`);
  viewer.on("message", (raw) => {
    const message = JSON.parse(raw.toString());
    if (message.type === "service-ready") {
      viewer.send(JSON.stringify({ type: "attach", sessionId: sessionID }));
      viewer.send(
        JSON.stringify({ type: "take-control", sessionId: sessionID }),
      );
    }
    if (message.data) {
      viewerOutput += message.data;
      appendFile(join(run, "terminal.txt"), message.data, { mode: 0o600 });
    }
    if (message.cursor !== undefined)
      viewer.send(
        JSON.stringify({
          type: "ack",
          sessionId: sessionID,
          cursor: message.cursor,
        }),
      );
  });
  await status("tui-starting", { run });
  rpc = await connect("control");
  report.auth = await rpc.call("account/read", { refreshToken: false });
  // Save only auth mode in the report, not account identifiers or plan metadata.
  report.auth = {
    type: report.auth.account?.type,
    requiresOpenaiAuth: report.auth.requiresOpenaiAuth,
  };
  // The TUI creates its first thread lazily on the user's initial submission.
  // This single bootstrap uses the normal terminal path; every measured task
  // below is delivered through the independent structured adapter.
  await until(
    () => viewerOutput.includes("state=idle:app=codex"),
    "TUI input ready",
    30000,
  );
  await service.paste(
    sessionID,
    randomUUID(),
    prompt(
      "Call record with label bootstrap exactly once, then say BOOTSTRAP-READY.",
    ),
    true,
  );
  await effect("bootstrap");
  // A remote TUI can also create an empty placeholder thread. Bind by the actual
  // bootstrap message in this owned runtime, never by list order or cwd alone.
  threadID = await until(async () => {
    const loaded = await rpc.call("thread/loaded/list");
    const matches = [];
    for (const id of loaded.data) {
      try {
        const page = await rpc.call("thread/items/list", {
          threadId: id,
          limit: 100,
          sortDirection: "desc",
        });
        if (
          page.data.some(
            (x) =>
              x.item?.type === "userMessage" &&
              x.item.content?.some(
                (c) =>
                  c.type === "text" &&
                  c.text.includes(
                    "Call record with label bootstrap exactly once",
                  ),
              ),
          )
        )
          matches.push(id);
      } catch (e) {
        if (
          !e.message.includes("no rollout") &&
          !e.message.includes("not found") &&
          !e.message.includes("thread/items/list is not supported yet")
        )
          throw e;
      }
    }
    assert(matches.length <= 1, "Ambiguous bootstrap binding");
    return matches[0];
  }, "thread containing the actual TUI bootstrap");
  report.threadID = threadID;
  await until(
    async () =>
      (await rpc.call("thread/read", { threadId: threadID })).thread.status
        .type === "idle",
    "bootstrap idle",
  );
  const attached = await rpc.call("thread/resume", {
    threadId: threadID,
    excludeTurns: true,
  });
  assert.equal(attached.thread.id, threadID);
  assert.equal(
    resolve(attached.cwd.replace(/^\/private\//, "/")),
    resolve(cwd.replace(/^\/private\//, "/")),
  );
  await until(
    async () =>
      (await rpc.call("thread/read", { threadId: threadID })).thread.status
        .type === "idle",
    "bootstrap idle",
  );
  report.checks.sameRuntimeAttachment = {
    establishedBy: "actual TUI bootstrap message in native thread history",
    threadID,
    status: attached.thread.status,
    model: attached.model,
    backendPID: backend.pid,
    loaded: await rpc.call("thread/loaded/list"),
  };
  await status("attached-existing-tui", { threadID });
  if (!process.argv.includes("--remaining")) {
    const idle = await rpc.call("turn/start", {
      threadId: threadID,
      clientUserMessageId: randomUUID(),
      input: input(
        prompt(
          "Call record with label idle exactly once, then finish with IDLE-DONE.",
        ),
      ),
    });
    await effect("idle");
    await completed(rpc, idle.turn.id);
    await until(
      () => viewerOutput.includes("IDLE-DONE"),
      "TUI sees externally submitted completion",
    );
    report.checks.idle = {
      turnID: idle.turn.id,
      effect: true,
      visibleInTUI: true,
    };
    await status("idle-delivery-passed");
    const busy = await rpc.call("turn/start", {
      threadId: threadID,
      clientUserMessageId: randomUUID(),
      input: input(
        prompt(
          "Call wait_gate with label busy. After it returns, call record with label busy-done, then finish.",
        ),
      ),
    });
    await gate("busy");
    const queued = await queue(
      "queued",
      "Call record with label queued exactly once, then finish with QUEUED-DONE.",
    );
    const duplicate = await rpc.call("thread/queue/add", {
      threadId: threadID,
      clientUserMessageId: queued.id,
      input: input(
        prompt(
          "Call record with label queued exactly once, then finish with QUEUED-DONE.",
        ),
      ),
    });
    let changed;
    try {
      changed = {
        result: await rpc.call("thread/queue/add", {
          threadId: threadID,
          clientUserMessageId: queued.id,
          input: input(
            prompt("Call record with label changed-duplicate then finish."),
          ),
        }),
      };
    } catch (e) {
      changed = { error: e.message };
    }
    const pending = await rpc.call("thread/queue/list", { threadId: threadID });
    assert(
      !(await entries()).some(
        (x) =>
          x.event === "effect" &&
          ["queued", "changed-duplicate"].includes(x.label),
      ),
    );
    let wrongTurn;
    try {
      wrongTurn = {
        result: await rpc.call("turn/steer", {
          threadId: threadID,
          expectedTurnId: randomUUID(),
          input: input(prompt("Call record with label wrong-turn.")),
        }),
      };
    } catch (e) {
      wrongTurn = { error: e.message };
    }
    assert(wrongTurn.error);
    const steer = await rpc.call("turn/steer", {
      threadId: threadID,
      expectedTurnId: busy.turn.id,
      clientUserMessageId: randomUUID(),
      input: input(
        prompt(
          "Change the current task: after wait_gate returns, record steered instead of busy-done, then finish. Do not process queued tasks as part of this turn.",
        ),
      ),
    });
    assert.equal(steer.turnId, busy.turn.id);
    report.checks.busyQueue = {
      turnID: busy.turn.id,
      queued,
      duplicate,
      changedArguments: changed,
      pending,
      noPrematureEffect: true,
      wrongTurn,
      steer,
    };
    await release("busy");
    await effect("steered");
    await completed(rpc, busy.turn.id);
    // Observe native auto-drain; start the queued item explicitly only if needed.
    await pause(1500);
    const after = await rpc.call("thread/read", { threadId: threadID });
    if (
      !(await entries()).some(
        (x) => x.event === "effect" && x.label === "queued",
      ) &&
      after.thread.status.type === "idle"
    ) {
      report.checks.busyQueue.explicitStart = await rpc.call(
        "thread/queue/start",
        { threadId: threadID, queuedSubmissionId: queued.queuedSubmission.id },
      );
    }
    await effect("queued");
    await until(
      async () =>
        (await rpc.call("thread/read", { threadId: threadID })).thread.status
          .type === "idle",
      "queued task idle",
    );
    report.checks.busyQueue.effects = await entries();
    await status("queue-and-steer-passed");
    report.checks.nativeQueueIdempotent =
      queued.queuedSubmission.id === duplicate.queuedSubmission.id;
  }

  const cli = await promisify(execFile)(
    codex,
    [
      "queue",
      "--remote",
      `unix://${socket}`,
      "--thread",
      threadID,
      "--message",
      prompt("Call record with label cli-queued exactly once, then finish."),
    ],
    { env, cwd, timeout: 15000 },
  );
  await writeFile(join(run, "queue-cli.txt"), cli.stdout + cli.stderr);
  await effect("cli-queued");
  await until(
    async () =>
      (await rpc.call("thread/read", { threadId: threadID })).thread.status
        .type === "idle",
    "CLI queue complete",
  );
  report.checks.cliQueue = {
    completedEffect: true,
    receipt: cli.stdout.trim(),
  };
  await status("cli-queue-passed");

  const held = await rpc.call("turn/start", {
    threadId: threadID,
    clientUserMessageId: randomUUID(),
    input: input(
      prompt(
        "Call wait_gate with label lost-reply. After it returns, record held-done exactly once and finish.",
      ),
    ),
  });
  await gate("lost-reply");
  const lostClient = await connect("lost");
  const rejoined = await lostClient.call("thread/resume", {
    threadId: threadID,
    excludeTurns: true,
  });
  const lostID = randomUUID();
  let uncertain;
  try {
    await lostClient.loseReply("thread/queue/add", {
      threadId: threadID,
      clientUserMessageId: lostID,
      input: input(
        prompt(
          "Call record with label recovered-once exactly once and finish.",
        ),
      ),
    });
  } catch (e) {
    uncertain = e.message;
  }
  assert(uncertain);
  const recoveredClient = await connect("recovered");
  const recovery = await recoveredClient.call("thread/resume", {
    threadId: threadID,
    excludeTurns: true,
  });
  const nativeQueue = await recoveredClient.call("thread/queue/list", {
    threadId: threadID,
  });
  const matches = nativeQueue.data.filter(
    (x) => x.clientUserMessageId === lostID,
  );
  assert.equal(matches.length, 1);
  report.checks.lostReply = {
    requestID: lostID,
    uncertain,
    rejoinedStatus: rejoined.thread.status,
    recoveryStatus: recovery.thread.status,
    recoveredQueuedSubmissionID: matches[0].id,
    resubmitted: false,
  };
  await release("lost-reply");
  await effect("held-done");
  await effect("recovered-once");
  await until(
    async () =>
      (await rpc.call("thread/read", { threadId: threadID })).thread.status
        .type === "idle",
    "recovered queue complete",
  );
  const history = await rpc.call("thread/items/list", {
    threadId: threadID,
    limit: 100,
    sortDirection: "desc",
  });
  await writeFile(
    join(run, "post-delivery-history.json"),
    JSON.stringify(history, null, 2),
  );
  report.checks.lostReply.historyContainsRequestID = history.data.some(
    (x) => x.item?.type === "userMessage" && x.item.clientId === lostID,
  );
  assert(report.checks.lostReply.historyContainsRequestID);
  report.checks.lostReply.effectCount = (await entries()).filter(
    (x) => x.event === "effect" && x.label === "recovered-once",
  ).length;
  assert.equal(report.checks.lostReply.effectCount, 1);
  await status("lost-reply-reconciled-without-retry");

  const stopping = await rpc.call("turn/start", {
    threadId: threadID,
    clientUserMessageId: randomUUID(),
    input: input(
      prompt(
        "Call wait_gate with label stop. After it returns, record forbidden-after-stop exactly once and finish.",
      ),
    ),
  });
  await gate("stop");
  const pendingStop = await queue(
    "after-stop",
    "Call record with label queued-after-stop exactly once and finish.",
  );
  const stopAt = performance.now();
  await rpc.call("turn/interrupt", {
    threadId: threadID,
    turnId: stopping.turn.id,
  });
  const ackMs = performance.now() - stopAt;
  const stopEvent = await completed(rpc, stopping.turn.id);
  await pause(1000);
  const queueAfterStop = await rpc.call("thread/queue/list", {
    threadId: threadID,
  });
  const stateAfterStop = await rpc.call("thread/read", { threadId: threadID });
  report.checks.interrupt = {
    turnID: stopping.turn.id,
    ackMs,
    endedStatus: stopEvent.params.turn.status,
    queueAfterStop,
    stateAfterStop: stateAfterStop.thread.status,
  };
  assert.equal(stopEvent.params.turn.status, "interrupted");
  if (
    queueAfterStop.data.some((x) => x.id === pendingStop.queuedSubmission.id)
  ) {
    await rpc.call("thread/queue/delete", {
      threadId: threadID,
      queuedSubmissionId: pendingStop.queuedSubmission.id,
    });
    report.checks.interrupt.pendingQueueExplicitlyDeleted = true;
  }
  await release("stop");
  await until(
    async () =>
      (await rpc.call("thread/read", { threadId: threadID })).thread.status
        .type === "idle",
    "idle after Stop",
  );
  await pause(500);
  report.checks.interrupt.forbiddenEffectCount = (await entries()).filter(
    (x) => x.event === "effect" && x.label === "forbidden-after-stop",
  ).length;
  report.checks.interrupt.queuedTaskRan = (await entries()).some(
    (x) => x.event === "effect" && x.label === "queued-after-stop",
  );
  assert.equal(report.checks.interrupt.forbiddenEffectCount, 0);
  await status("interrupt-observed");

  const permissionStart = rpc.events.length;
  const permission = await rpc.call("turn/start", {
    threadId: threadID,
    clientUserMessageId: randomUUID(),
    input: input(
      prompt(
        "Call ask_fixture_permission. If the operator accepts, record consent exactly once and finish; otherwise finish without recording.",
      ),
    ),
  });
  const question = await until(
    () =>
      rpc.events
        .slice(permissionStart)
        .find(
          (e) =>
            e.id !== undefined && e.method === "mcpServer/elicitation/request",
        ),
    "native elicitation request",
    30000,
  );
  report.checks.permissionWait = {
    requestMethod: question.method,
    pendingStatus: (await rpc.call("thread/read", { threadId: threadID }))
      .thread.status,
    noEffectBeforeConsent: !(await entries()).some(
      (x) => x.event === "effect" && x.label === "consent",
    ),
  };
  assert(report.checks.permissionWait.noEffectBeforeConsent);
  // The user authorized this disposable test marker; this is the concrete fixture
  // elicitation only, not a change to any system permission or approval policy.
  rpc.send({
    id: question.id,
    result: { action: "accept", content: { permit: true } },
  });
  await effect("consent");
  await completed(rpc, permission.turn.id);
  report.checks.permissionWait.completed = true;
  await status("native-user-input-wait-passed");

  // Exit only the owned TUI. SessionManager intentionally retains its shell.
  viewer.send(
    JSON.stringify({ type: "input", sessionId: sessionID, data: "\u0004" }),
  );
  await until(
    () => viewerOutput.includes("SLZ_AGENT_EXITED"),
    "TUI exit into retained shell",
    15000,
  );
  const infoAfterExit = await service.info();
  const loadedAfterExit = await rpc.call("thread/loaded/list");
  report.checks.tuiExit = {
    terminalStillRunning: infoAfterExit.sessions.some(
      (x) => x.id === sessionID && x.status === "running",
    ),
    nativeThreadStillLoaded: loadedAfterExit.data.includes(threadID),
    backgroundRuntimeStillOwned: backend.exitCode === null,
  };
  // Do not fallback to PTY text. Explicitly detach controller clients, then inspect
  // saved-vs-loaded state. A retained history row is not a live worker binding.
  await rpc.call("thread/unsubscribe", { threadId: threadID });
  await recoveredClient.call("thread/unsubscribe", { threadId: threadID });
  await pause(1200);
  report.checks.tuiExit.loadedAfterUnsubscribe =
    await rpc.call("thread/loaded/list");
  let staleSteer;
  try {
    staleSteer = {
      result: await rpc.call("turn/steer", {
        threadId: threadID,
        expectedTurnId: permission.turn.id,
        input: input(prompt("Call record stale-after-exit.")),
      }),
    };
  } catch (e) {
    staleSteer = { error: e.message };
  }
  report.checks.tuiExit.staleSteer = staleSteer;
  report.checks.tuiExit.unloadObservationMs = 1200;
  assert(staleSteer.error);
  report.checks.tuiExit.shellTextFallbackUsed = false;
  await status("tui-exit-and-stale-steer-checked");
  report.completed = true;
} catch (e) {
  report.completed = false;
  report.error = e.stack;
  process.exitCode = 1;
  await status("failed", { error: e.message });
} finally {
  for (const client of rpcs) await client.close().catch(() => {});
  viewer?.close();
  if (service) {
    await service.end(sessionID).catch(() => {});
    await service
      .stop()
      .then(() => (report.serviceStopped = true))
      .catch((e) => (report.cleanupError = e.message));
  }
  if (backend && backend.exitCode === null) backend.kill("SIGTERM");
  if (backendDone) report.backendExit = await backendDone;
  await rm(privateDir, { recursive: true, force: true });
  report.credentialsRemoved = true;
  report.finishedAt = new Date().toISOString();
  await save();
  console.log(
    JSON.stringify({
      run,
      completed: report.completed,
      checks: Object.keys(report.checks),
      cleaned: report.credentialsRemoved,
    }),
  );
}
