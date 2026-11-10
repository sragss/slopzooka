import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import {
  mkdtemp,
  mkdir,
  readFile,
  writeFile,
  cp,
  chmod,
  rm,
  appendFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { generateKeyPairSync, createHash, randomUUID } from "node:crypto";
import { chromium } from "playwright-core";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { startBridge } from "./bridge.mjs";
import { connectHumanFixture } from "./test-driver.mjs";

const base = dirname(fileURLToPath(import.meta.url));
await mkdir(join(base, "build"), { recursive: true });
const run = await mkdtemp(join(base, "build", "run-"));
const privateDir = await mkdtemp(join(tmpdir(), "slz-own-"));
await chmod(privateDir, 0o700);
const socketPath = join(privateDir, "bridge.sock");
const profile = join(privateDir, "profile");
const extensionDir = join(privateDir, "extension");
const ordinaryEnv = Object.fromEntries(
  ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"]
    .filter((key) => process.env[key])
    .map((key) => [key, process.env[key]]),
);
const fixtureEvents = [];
let blockStarted = 0;
const results = [];
const clients = [];
let chrome, chromeExit, bridge, nativePid, humanDriver, endpoint;
let chromeDiagnostics = "";
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(fn, description, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await fn();
    if (value) return value;
    await pause(50);
  }
  throw new Error(`Timed out: ${description}`);
}
async function record(name, action) {
  const start = performance.now();
  try {
    const detail = await action();
    const row = {
      name,
      passed: true,
      elapsedMs: Math.round(performance.now() - start),
      detail,
    };
    results.push(row);
    console.log(JSON.stringify(row));
    await appendFile(join(run, "results.jsonl"), JSON.stringify(row) + "\n");
    return detail;
  } catch (error) {
    const row = {
      name,
      passed: false,
      elapsedMs: Math.round(performance.now() - start),
      error: error.message,
    };
    results.push(row);
    console.log(JSON.stringify(row));
    await appendFile(join(run, "results.jsonl"), JSON.stringify(row) + "\n");
    throw error;
  }
}
let fixture = await readFile(
  new URL("../browser-runtime-probe/fixture.html", import.meta.url),
  "utf8",
);
if (process.argv.includes("--streaming")) {
  fixture += await readFile(
    new URL("./stream-fixture.html", import.meta.url),
    "utf8",
  );
}
const server = createServer(async (req, res) => {
  await appendFile(
    join(run, "fixture-requests.jsonl"),
    JSON.stringify({
      method: req.method,
      path: req.url,
      origin: req.headers.origin,
      host: req.headers.host,
    }) + "\n",
  );
  if (
    req.url === "/block-start" &&
    req.method === "POST" &&
    req.headers.origin === origin
  ) {
    blockStarted++;
    res.end("ok");
  } else if (req.url === "/event" && req.method === "POST") {
    if (
      req.headers.origin !== origin ||
      req.headers.host !== new URL(origin).host
    ) {
      res.writeHead(403).end();
      return;
    }
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > 8192) {
        res.writeHead(413).end();
        return;
      }
      chunks.push(chunk);
    }
    const event = JSON.parse(Buffer.concat(chunks));
    fixtureEvents.push({ sequence: fixtureEvents.length + 1, ...event });
    await appendFile(
      join(run, "fixture-events.jsonl"),
      JSON.stringify(fixtureEvents.at(-1)) + "\n",
    );
    res.end("ok");
  } else if (req.url === "/frame") {
    res.setHeader("Content-Type", "text/html");
    res.end(
      "<button onclick=\"this.textContent='Frame clicked'\">Frame action</button>",
    );
  } else {
    res.setHeader("Content-Type", "text/html");
    res.end(
      fixture +
        "<button id=\"block\" onclick=\"navigator.sendBeacon('/block-start', 'started'); const end=performance.now()+700; while(performance.now()<end) {}\">Block renderer</button>",
    );
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;

async function mcp(name) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(base, "mcp.mjs"), socketPath],
    env: ordinaryEnv,
    stderr: "pipe",
  });
  const client = new Client({ name, version: "0.1.0" });
  await client.connect(transport);
  clients.push(client);
  return {
    client,
    async raw(tool, args = {}) {
      return client.callTool({ name: tool, arguments: args });
    },
    async call(tool, args = {}) {
      const reply = await this.raw(tool, args);
      if (reply.isError) throw new Error(reply.content[0].text);
      return JSON.parse(
        reply.content.find((part) => part.type === "text").text,
      );
    },
  };
}
function ref(state, role, name) {
  const matches = state.elements.filter(
    (entry) => entry.role === role && entry.name === name && entry.ref,
  );
  assert.equal(matches.length, 1, `Unique ${role} ${name}`);
  return matches[0].ref;
}
function fixtureCount(path) {
  return fixtureEvents.filter(
    (event) => event.fixture === path && event.action === "increment",
  ).length;
}
const shellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";

try {
  await cp(join(base, "extension"), extensionDir, { recursive: true });
  const { publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const key = publicKey.export({ type: "spki", format: "der" });
  const extensionId = [
    ...createHash("sha256").update(key).digest().subarray(0, 16),
  ]
    .map((byte) => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15)))
    .join("");
  const manifest = JSON.parse(
    await readFile(join(extensionDir, "manifest.json"), "utf8"),
  );
  manifest.key = key.toString("base64");
  await writeFile(
    join(extensionDir, "manifest.json"),
    JSON.stringify(manifest, null, 2),
  );
  const hostName = `dev.slopzooka.probe_${randomUUID().replaceAll("-", "")}`;
  const token = randomUUID();
  const configPath = join(privateDir, "native-config.json");
  await writeFile(
    configPath,
    JSON.stringify({
      socketPath,
      token,
      extensionOrigin: `chrome-extension://${extensionId}/`,
    }),
    { mode: 0o600 },
  );
  await writeFile(
    join(extensionDir, "config.js"),
    `export const config = ${JSON.stringify({ origin, hostName })};\n`,
  );
  // Chrome's native child does not need access to the user's Documents folder.
  // Stage only our two dependency-free bridge files beside the private socket.
  await cp(join(base, "native-host.mjs"), join(privateDir, "native-host.mjs"));
  await cp(join(base, "wire.mjs"), join(privateDir, "wire.mjs"));
  const launcher = join(privateDir, "native-host");
  await writeFile(
    launcher,
    `#!/bin/sh\nexec ${shellQuote(process.execPath)} ${shellQuote(join(privateDir, "native-host.mjs"))} ${shellQuote(configPath)} "$@"\n`,
    { mode: 0o700 },
  );
  // Modern Chrome reads user native hosts beneath this isolated user-data-dir.
  // No host manifest is installed in the user's everyday Chrome profile.
  const hosts = join(profile, "NativeMessagingHosts");
  await mkdir(hosts, { recursive: true });
  await writeFile(
    join(hosts, `${hostName}.json`),
    JSON.stringify({
      name: hostName,
      description: "Disposable SlopZooka probe",
      path: launcher,
      type: "stdio",
      allowed_origins: [`chrome-extension://${extensionId}/`],
    }),
  );
  bridge = await startBridge({ socketPath, token });
  const dispatches = [];
  bridge.events.on("event", (event) => {
    dispatches.push({ at: performance.now(), ...event });
  });
  bridge.events.on("connected", ({ pid }) => {
    nativePid = pid;
  });
  chrome = spawn(
    chromium.executablePath(),
    [
      `--user-data-dir=${profile}`,
      `--load-extension=${extensionDir}`,
      `--disable-extensions-except=${extensionDir}`,
      ...(process.argv.includes("--headed") ? [] : ["--headless=new"]),
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--window-size=1100,850",
      "--remote-debugging-address=127.0.0.1",
      "--remote-debugging-port=0",
      `${origin}/human`,
    ],
    { env: ordinaryEnv, cwd: privateDir, stdio: ["ignore", "ignore", "pipe"] },
  );
  chromeExit = new Promise((resolve) => chrome.once("exit", resolve));
  chrome.stderr.on("data", (data) => {
    chromeDiagnostics = (chromeDiagnostics + data).slice(-12000);
  });
  await record("real_extension_native_host_connected", async () => {
    await until(() => bridge.status.connected, "extension native host", 20000);
    const port = (
      await readFile(join(profile, "DevToolsActivePort"), "utf8")
    ).split("\n")[0];
    endpoint = `http://127.0.0.1:${port}`;
    const version = await (await fetch(`${endpoint}/json/version`)).json();
    return {
      browser: version.Browser,
      node: process.version,
      headed: process.argv.includes("--headed"),
      extensionId,
      nativeHostPid: nativePid,
    };
  });
  if (process.argv.includes("--streaming")) {
    const { runStreaming } = await import("./streaming.mjs");
    await runStreaming({
      bridge,
      socketPath,
      origin,
      run,
      endpoint,
      fixtureEvents,
      headed: process.argv.includes("--headed"),
      serve: process.argv.includes("--serve"),
    });
  } else if (process.argv.includes("--serve")) {
    // A concrete, temporary MCP endpoint for a manually configured terminal agent.
    // No edits to global Codex/Pi configuration or the user's Chrome installation.
    const stopped = new Promise((resolve) => {
      process.once("SIGINT", resolve);
      process.once("SIGTERM", resolve);
    });
    console.log(
      JSON.stringify({
        kind: "serve-ready",
        artifacts: run,
        fixtureOrigin: origin,
        mcp: {
          command: process.execPath,
          args: [join(base, "mcp.mjs"), socketPath],
        },
        instructions:
          "Use only fixture URLs under this origin. Ctrl-C closes this owned test browser and bridge.",
      }),
    );
    await stopped;
  } else {
    const a = await mcp("agent-a");
    const b = await mcp("agent-b");
    const tabA = await a.call("browser_open", { url: `${origin}/a` });
    const tabB = await b.call("browser_open", { url: `${origin}/b` });
    const human = (await a.call("browser_tabs")).find(
      (tab) => tab.url === `${origin}/human`,
    );
    assert(human?.active);
    humanDriver = await connectHumanFixture(endpoint, `${origin}/human`);
    const stateA = await a.call("browser_observe", { target: tabA.target });
    const stateB = await b.call("browser_observe", { target: tabB.target });

    await record("two_mcp_clients_background_input", async () => {
      async function drive(client, tab, state, label) {
        await client.call("browser_fill", {
          target: tab.target,
          ref: ref(state, "textbox", "Workspace label"),
          text: label,
        });
        await client.call("browser_click", {
          target: tab.target,
          ref: ref(state, "button", "Save label"),
        });
        for (let i = 0; i < 2; i++)
          await client.call("browser_click", {
            target: tab.target,
            ref: ref(state, "button", "Increment"),
          });
        await client.call("browser_click", {
          target: tab.target,
          ref: ref(state, "button", "Settings"),
        });
      }
      const [, , humanState] = await Promise.all([
        drive(a, tabA, stateA, "owned-a"),
        drive(b, tabB, stateB, "owned-b"),
        humanDriver.type("human-keeps-typing"),
      ]);
      await writeFile(
        join(run, "background-state.json"),
        JSON.stringify(
          {
            a: await a.call("browser_observe", { target: tabA.target }),
            b: await b.call("browser_observe", { target: tabB.target }),
            human: humanState,
          },
          null,
          2,
        ),
      );
      await until(() => fixtureEvents.length >= 8, "8 fixture events");
      for (const [path, label] of [
        ["/a", "owned-a"],
        ["/b", "owned-b"],
      ]) {
        const rows = fixtureEvents.filter((event) => event.fixture === path);
        assert.deepEqual(
          rows.map((event) => event.action),
          ["save", "increment", "increment", "settings"],
        );
        assert(rows.every((event) => event.label === label));
        assert.equal(rows.at(-1).count, 2);
      }
      assert(
        (await a.call("browser_tabs")).find((tab) => tab.tabId === human.tabId)
          .active,
      );
      assert.equal(humanState.value, "human-keeps-typing");
      assert.equal(humanState.caret, "human-keeps-typing".length);
      assert.equal(humanState.visible, "visible");
      assert.equal(humanState.focused, true);
      return {
        fixtureEvents: 8,
        counterA: 2,
        counterB: 2,
        foregroundTabUnchanged: true,
        simulatedHumanTypingIntact: true,
        humanDocumentFocused: humanState.focused,
      };
    });
    await record("ownership_and_origin_rejection", async () => {
      assert((await b.raw("browser_claim", { tabId: tabA.tabId })).isError);
      assert(
        (
          await b.raw("browser_click", {
            target: tabA.target,
            ref: ref(stateA, "button", "Increment"),
          })
        ).isError,
      );
      assert(
        (await a.raw("browser_open", { url: "https://example.com/" })).isError,
      );
      assert.equal(fixtureCount("/a"), 2);
      return {
        conflictingClaimRejected: true,
        foreignTargetRejected: true,
        foreignOriginRejected: true,
      };
    });
    await record("real_background_screenshot", async () => {
      const result = await a.raw("browser_screenshot", { target: tabA.target });
      assert(!result.isError);
      const image = result.content.find((part) => part.type === "image");
      assert(image?.data.length > 1000);
      await writeFile(
        join(run, "background-a.jpg"),
        Buffer.from(image.data, "base64"),
      );
      return {
        mimeType: image.mimeType,
        bytes: Buffer.from(image.data, "base64").length,
      };
    });
    await record("navigation_invalidates_refs", async () => {
      await a.call("browser_navigate", {
        target: tabA.target,
        url: `${origin}/a?next=1`,
      });
      await pause(250);
      const stale = await a.raw("browser_click", {
        target: tabA.target,
        ref: ref(stateA, "button", "Increment"),
      });
      assert(stale.isError);
      const fresh = await a.call("browser_observe", { target: tabA.target });
      await a.call("browser_click", {
        target: tabA.target,
        ref: ref(fresh, "button", "Increment"),
      });
      await until(() => fixtureCount("/a") === 3, "fresh navigation action");
      return { staleRejected: true, freshActionWorked: true };
    });
    await record("stop_revokes_queued_input_without_stopping_b", async () => {
      const fresh = await a.call("browser_observe", { target: tabA.target });
      const beforeBlock = blockStarted;
      const block = a.raw("browser_click", {
        target: tabA.target,
        ref: ref(fresh, "button", "Block renderer"),
      });
      // Independent beacon establishes that the click took effect and the renderer
      // is now busy. Stop cannot undo that click, but must revoke queued input.
      await until(
        () => blockStarted > beforeBlock,
        "renderer entered blocking click handler",
      );
      const queued = Array.from({ length: 12 }, () =>
        a.raw("browser_click", {
          target: tabA.target,
          ref: ref(fresh, "button", "Increment"),
        }),
      );
      const stopStart = performance.now();
      const stopped = await a.call("browser_stop");
      const stopAckMs = Math.round(performance.now() - stopStart);
      const outcomes = await Promise.all(queued);
      await block;
      assert(outcomes.every((outcome) => outcome.isError));
      await pause(800);
      assert.equal(fixtureCount("/a"), 3);
      const freshB = await b.call("browser_observe", { target: tabB.target });
      await b.call("browser_click", {
        target: tabB.target,
        ref: ref(freshB, "button", "Increment"),
      });
      await until(() => fixtureCount("/b") === 3, "B survives A Stop");
      return {
        ...stopped,
        initialClickActuallyRan: true,
        stopAckMs,
        queuedRejected: outcomes.length,
        extraAIncrements: 0,
        bContinued: true,
      };
    });
    await record(
      "native_bridge_restart_revokes_targets_without_replay",
      async () => {
        const before = bridge.status;
        const oldState = await b.call("browser_observe", {
          target: tabB.target,
        });
        const beforeBlock = blockStarted;
        const uncertain = b.raw("browser_click", {
          target: tabB.target,
          ref: ref(oldState, "button", "Block renderer"),
        });
        await until(
          () => blockStarted > beforeBlock,
          "in-flight click before native-host crash",
        );
        process.kill(before.pid, "SIGTERM");
        const uncertainResult = await uncertain;
        assert(uncertainResult.isError);
        assert.match(
          uncertainResult.content[0].text,
          /disconnected; effects may have occurred/,
        );
        await until(
          () => bridge.status.epoch > before.epoch,
          "native host reconnect",
        );
        assert(
          (await b.raw("browser_observe", { target: tabB.target })).isError,
        );
        const reclaimed = await b.call("browser_claim", { tabId: tabB.tabId });
        const state = await b.call("browser_observe", {
          target: reclaimed.target,
        });
        await b.call("browser_click", {
          target: reclaimed.target,
          ref: ref(state, "button", "Increment"),
        });
        await until(
          () => fixtureCount("/b") === 4,
          "fresh input after bridge restart",
        );
        return {
          inFlightReportedUncertain: true,
          oldTargetRejected: true,
          newNativeHost: before.pid !== bridge.status.pid,
          counterB: 4,
        };
      },
    );
    await record("closed_target_is_not_retargeted", async () => {
      const c = await mcp("agent-close");
      const tab = await c.call("browser_open", { url: `${origin}/closing` });
      const observer = await connectHumanFixture(endpoint, `${origin}/closing`);
      try {
        await observer.closeTab().catch(() => {});
      } finally {
        observer.close();
      }
      await until(
        async () =>
          !(await c.call("browser_tabs")).some(
            (entry) => entry.tabId === tab.tabId,
          ),
        "tab close",
      );
      assert((await c.raw("browser_observe", { target: tab.target })).isError);
      assert(
        (await c.call("browser_tabs")).some(
          (entry) => entry.tabId === tabB.tabId,
        ),
      );
      await c.client.close();
      return { staleTargetRejected: true, bStillPresent: true };
    });
    // An owned Pi loop can use this same MCP server; enabled explicitly so CI stays model-free.
    if (process.argv.includes("--models")) {
      const { runModels } = await import("./models.mjs");
      const keyIndex = process.argv.indexOf("--key-file");
      await record("live_pi_models", () =>
        runModels({
          socketPath,
          origin,
          run,
          fixtureEvents,
          keyFile: keyIndex < 0 ? undefined : process.argv[keyIndex + 1],
        }),
      );
    }
    await record("mcp_disconnect_releases_only_its_targets", async () => {
      await b.client.close();
      const c = await mcp("agent-c");
      await until(
        async () =>
          !(await c.call("browser_tabs")).find(
            (tab) => tab.tabId === tabB.tabId,
          ).claimed,
        "disconnect release",
      );
      const claimed = await c.call("browser_claim", { tabId: tabB.tabId });
      assert(
        (await c.call("browser_observe", { target: claimed.target })).elements
          .length,
      );
      return { reclaimedByNewClient: true };
    });
  }
} catch (error) {
  await writeFile(
    join(run, "failure.txt"),
    error.stack + "\n" + chromeDiagnostics,
  );
  process.exitCode = 1;
  console.error(error.message);
} finally {
  for (const client of clients) await client.close().catch(() => {});
  humanDriver?.close();
  await bridge?.close();
  if (chrome?.exitCode === null) {
    chrome.kill("SIGTERM");
    await chromeExit;
  }
  await new Promise((resolve) => server.close(resolve));
  await rm(privateDir, { recursive: true, force: true });
  await writeFile(
    join(run, "summary.json"),
    JSON.stringify(
      { at: new Date().toISOString(), results, fixtureEvents, run },
      null,
      2,
    ),
  );
  console.log(
    JSON.stringify({
      run,
      passed: results.filter((row) => row.passed).length,
      failed: results.filter((row) => !row.passed).length,
      exitCode: process.exitCode ?? 0,
    }),
  );
}
