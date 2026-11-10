import {
  requireIdleDeviceDriver,
  stopOwnedDeviceDriver,
} from "./owned-device-processes.mjs";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  writeFile,
  appendFile,
  open,
  readFile,
} from "node:fs/promises";
import { createServer } from "node:net";
import { fileURLToPath } from "node:url";
import { dirname, resolve, join } from "node:path";
import { parseArgs } from "node:util";
import { randomUUID } from "node:crypto";
import { FrameRelay, startMediaServer } from "../owned-browser-probe/media.mjs";
import { MJPEGParser } from "./mjpeg.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const probe = join(root, "experiments/shared-window-probe");
const { values } = parseArgs({
  options: {
    udid: { type: "string" },
    workspace: { type: "string", default: "probe-workspace" },
    smoke: { type: "boolean" },
    prepare: { type: "boolean" },
  },
});
if (!/^[0-9a-f-]{36}$/i.test(values.udid ?? ""))
  throw new Error("Pass --udid with the explicit disposable simulator UUID");
const device = Object.values(
  JSON.parse(
    execFileSync(
      "xcrun",
      ["simctl", "list", "devices", "available", "--json"],
      { encoding: "utf8" },
    ),
  ).devices,
)
  .flat()
  .find((d) => d.udid === values.udid);
if (!device || !device.name.toLowerCase().includes("probe"))
  throw new Error(
    "Only a deliberately named disposable probe simulator is admitted",
  );
await mkdir(join(root, "experiments/surface-live-probe/build"), {
  recursive: true,
});
const run = await mkdtemp(
  join(root, "experiments/surface-live-probe/build/run-"),
);
const bundle = "com.slopzooka.probe.fixture",
  target = `ios:${values.udid}`,
  surfaceID = `probe:${values.udid}`;
const nonce = randomUUID().slice(0, 8),
  relay = new FrameRelay();
relay.add(target, `iOS fixture • ${nonce}`);
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
async function freePort() {
  const s = createServer();
  await new Promise((r, j) => {
    s.once("error", j);
    s.listen(0, "127.0.0.1", r);
  });
  const p = s.address().port;
  await new Promise((r) => s.close(r));
  return p;
}
const appiumPort = await freePort(),
  wdaPort = await freePort(),
  mjpegPort = await freePort();
let child,
  exited,
  sessionID,
  media,
  streamController,
  streamTask,
  booted = false,
  stopped = false,
  generation = 1,
  refs = new Map(),
  tail = Promise.resolve();
let sourceHealthy = false,
  stopRequested = false;
const runStopped = new Promise((resolve) => {
  for (const signal of ["SIGINT", "SIGTERM"])
    process.once(signal, () => {
      stopRequested = true;
      stopped = true;
      generation++;
      refs.clear();
      streamController?.abort();
      resolve();
    });
});
const driver = `http://127.0.0.1:${appiumPort}`;
async function api(method, path, body, timeout = 15000) {
  const response = await fetch(driver + path, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeout),
  });
  const raw = await response.text();
  if (raw.length > 16 * 1024 * 1024)
    throw new Error("Driver response exceeded");
  const result = JSON.parse(raw);
  if (!response.ok || result.value?.error)
    throw new Error(
      `Driver ${response.status}: ${JSON.stringify(result.value).slice(0, 500)}`,
    );
  return result.value;
}
async function verify() {
  const value = await api("GET", `/session/${sessionID}`);
  const caps = value.capabilities ?? value;
  if ((caps.udid ?? caps["appium:udid"]) !== values.udid)
    throw new Error("Device identity mismatch");
  const app = await api("POST", `/session/${sessionID}/execute/sync`, {
    script: "mobile: activeAppInfo",
    args: [],
  });
  if (app.bundleId !== bundle)
    throw new Error(
      `Fixture is not the active simulator app (${app.bundleId})`,
    );
  return { udid: values.udid, sessionID, bundleId: app.bundleId, pid: app.pid };
}
let appPID, lastObservation;
async function verified() {
  const state = await verify();
  if (appPID !== undefined && appPID !== state.pid) {
    stopped = true;
    generation++;
    refs.clear();
    relay.pause(target, "App replaced; explicitly resume and observe");
    throw new Error("App process replaced");
  }
  appPID = state.pid;
  return state;
}
async function observe() {
  const identity = await verified();
  const xml = await api("GET", `/session/${sessionID}/source`);
  const rows = JSON.parse(
    execFileSync(
      "python3",
      [
        "-c",
        `import sys,json,xml.etree.ElementTree as E
root=E.fromstring(sys.stdin.read()); rows=[dict(e.attrib) for e in root.iter() if e.attrib.get('name') and e.attrib.get('visible')!='false']; counts={}
for r in rows:counts[r['name']]=counts.get(r['name'],0)+1
print(json.dumps([r for r in rows if counts[r['name']]==1][:160]))`,
      ],
      { input: xml, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 },
    ),
  );
  refs.clear();
  const observation = randomUUID();
  const elements = rows.map((r, i) => {
    const ref = `${observation}:${i}`;
    refs.set(ref, r.name);
    return {
      ref,
      type: r.type,
      name: r.name,
      label: r.label,
      value: r.value,
      enabled: r.enabled,
    };
  });
  const rect = await api("GET", `/session/${sessionID}/window/rect`);
  const image = await api("GET", `/session/${sessionID}/screenshot`);
  const png = Buffer.from(image, "base64");
  if (png.readUInt32BE(0) !== 0x89504e47)
    throw new Error("Expected PNG observation");
  lastObservation = {
    id: observation,
    generation,
    rect,
    width: png.readUInt32BE(16),
    height: png.readUInt32BE(20),
  };
  return {
    ...identity,
    generation,
    observation,
    imageCoordinates: {
      width: lastObservation.width,
      height: lastObservation.height,
      unit: "image pixels",
    },
    elements,
    image: { mimeType: "image/png", data: image },
  };
}
async function control({ tool, args = {} }) {
  if (tool === "surface_stop") {
    stopped = true;
    generation++;
    refs.clear();
    return {
      stopped: true,
      generation,
      note: "Queued input revoked. Dispatched input cannot be undone. Stream remains attached.",
    };
  }
  if (tool === "surface_resume") {
    await tail.catch(() => {});
    const identity = await verify();
    if (!sourceHealthy)
      throw new Error(
        "Stream unavailable; restart the isolated provider instead of silently reattaching",
      );
    appPID = identity.pid;
    stopped = false;
    generation++;
    refs.clear();
    relay.bind(target, sessionID);
    return { resumed: true, generation };
  }
  const admitted = generation;
  const work = tail.then(async () => {
    if (stopped || admitted !== generation)
      throw new Error("Stopped or replaced; explicitly resume then observe");
    if (tool === "surface_observe") return observe();
    if (
      ![
        "surface_press",
        "surface_fill",
        "surface_swipe",
        "surface_tap",
      ].includes(tool)
    )
      throw new Error("Unknown simulator operation");
    await verified();
    if (stopped || admitted !== generation)
      throw new Error("Stopped before input");
    let route, body;
    if (tool === "surface_tap") {
      const o = lastObservation;
      if (
        !o ||
        o.id !== args.observation ||
        o.generation !== generation ||
        !Number.isFinite(args.x) ||
        !Number.isFinite(args.y) ||
        args.x < 0 ||
        args.y < 0 ||
        args.x >= o.width ||
        args.y >= o.height
      )
        throw new Error("Stale observation or out-of-image coordinates");
      const rect = await api("GET", `/session/${sessionID}/window/rect`);
      if (JSON.stringify(rect) !== JSON.stringify(o.rect))
        throw new Error("Viewport changed; observe again");
      if (stopped || admitted !== generation)
        throw new Error("Stopped before tap");
      route = "/execute/sync";
      body = {
        script: "mobile: tap",
        args: [
          {
            x: rect.x + (args.x * rect.width) / o.width,
            y: rect.y + (args.y * rect.height) / o.height,
          },
        ],
      };
    } else if (tool === "surface_swipe") {
      if (!["up", "down"].includes(args.direction))
        throw new Error("Invalid direction");
      route = "/execute/sync";
      body = { script: "mobile: swipe", args: [{ direction: args.direction }] };
    } else {
      const name = refs.get(args.ref);
      if (!name) throw new Error("Stale element; observe again");
      const e = await api("POST", `/session/${sessionID}/element`, {
        using: "accessibility id",
        value: name,
      });
      const id = e["element-6066-11e4-a52e-4f735466cecf"] ?? e.ELEMENT;
      if (!id) throw new Error("Missing element");
      if (stopped || admitted !== generation)
        throw new Error("Stopped before dispatch");
      if (tool === "surface_fill") {
        if (typeof args.text !== "string" || args.text.length > 200)
          throw new Error("Invalid fixture text");
        await api("POST", `/session/${sessionID}/element/${id}/clear`, {});
        if (stopped || admitted !== generation)
          throw new Error("Stopped after clear; inspect partial effect");
        route = `/element/${id}/value`;
        body = { text: args.text, value: [...args.text] };
      } else {
        route = `/element/${id}/click`;
        body = {};
      }
    }
    refs.clear();
    lastObservation = undefined;
    await api("POST", `/session/${sessionID}${route}`, body);
    await appendFile(
      join(run, "effects.jsonl"),
      JSON.stringify({ at: Date.now(), tool, generation, sessionID }) + "\n",
    );
    return {
      dispatched: true,
      generation,
      note: "Observe to verify actual effects",
    };
  });
  tail = work.catch(() => {});
  try {
    return await work;
  } catch (error) {
    // Driver timeouts/transport errors leave effects uncertain. Do not replay.
    if (/Driver|fetch|timeout|aborted/i.test(error.message)) {
      stopped = true;
      generation++;
      refs.clear();
    }
    throw error;
  }
}
try {
  requireIdleDeviceDriver(values.udid, probe);
  if (device.state !== "Booted") {
    if (!values.prepare)
      throw new Error(
        "Simulator is shut down. Use --prepare to boot/install only this disposable fixture",
      );
    execFileSync("xcrun", ["simctl", "boot", values.udid], { stdio: "ignore" });
    booted = true;
    execFileSync("xcrun", ["simctl", "bootstatus", values.udid, "-b"], {
      stdio: "ignore",
      timeout: 120000,
    });
  }
  if (values.prepare) {
    execFileSync(
      "xcrun",
      [
        "simctl",
        "install",
        values.udid,
        join(
          probe,
          "build/DerivedData/Build/Products/Debug-iphonesimulator/ProbeFixture.app",
        ),
      ],
      { stdio: "ignore" },
    );
    execFileSync("xcrun", ["simctl", "launch", values.udid, bundle], {
      stdio: "ignore",
    });
  }
  execFileSync(
    "xcrun",
    ["simctl", "openurl", values.udid, `slz-probe://nonce?value=${nonce}`],
    { stdio: "ignore" },
  );
  const log = await open(join(run, "appium.log"), "w");
  const env = { ...process.env };
  delete env.APPIUM_HOME;
  child = spawn(
    join(probe, "tooling/node_modules/.bin/appium"),
    [
      "--address",
      "127.0.0.1",
      "--port",
      String(appiumPort),
      "--use-drivers",
      "xcuitest",
    ],
    {
      cwd: join(probe, "tooling"),
      env,
      stdio: ["ignore", log.fd, log.fd],
      detached: true,
    },
  );
  exited = new Promise((r) => {
    child.once("exit", r);
    child.once("error", r);
  });
  let ready = false;
  for (let i = 0; i < 100; i++) {
    try {
      await api("GET", "/status", undefined, 1000);
      ready = true;
      break;
    } catch {
      if (child.exitCode !== null) break;
      await pause(200);
    }
  }
  if (!ready) throw new Error("Owned Appium did not start; see log");
  const session = await api(
    "POST",
    "/session",
    {
      capabilities: {
        alwaysMatch: {
          platformName: "iOS",
          "appium:automationName": "XCUITest",
          "appium:udid": values.udid,
          "appium:bundleId": bundle,
          "appium:noReset": true,
          "appium:autoLaunch": false,
          "appium:forceAppLaunch": false,
          "appium:shouldTerminateApp": false,
          "appium:isHeadless": false,
          "appium:shutdownOtherSimulators": false,
          "appium:wdaLocalPort": wdaPort,
          "appium:mjpegServerPort": mjpegPort,
          "appium:wdaBindingIP": "127.0.0.1",
          "appium:usePrebuiltWDA": true,
          "appium:derivedDataPath": join(probe, "build/wda-derived"),
          "appium:wdaLaunchTimeout": 45000,
          "appium:wdaConnectionTimeout": 15000,
          "appium:wdaStartupRetries": 1,
          "appium:newCommandTimeout": 3600,
        },
      },
    },
    90000,
  );
  sessionID = session.sessionId;
  if (!sessionID) throw new Error("Missing session ID");
  if (values.prepare) {
    await api("POST", `/session/${sessionID}/execute/sync`, {
      script: "mobile: activateApp",
      args: [{ bundleId: bundle }],
    });
    execFileSync(
      "xcrun",
      ["simctl", "openurl", values.udid, `slz-probe://nonce?value=${nonce}`],
      { stdio: "ignore" },
    );
  }
  await verified();
  await api("POST", `/session/${sessionID}/appium/settings`, {
    settings: {
      mjpegServerFramerate: 15,
      mjpegScalingFactor: 60,
      mjpegServerScreenshotQuality: 25,
    },
  });
  relay.bind(target, sessionID);
  streamController = new AbortController();
  streamTask = (async () => {
    const response = await fetch(`http://127.0.0.1:${mjpegPort}`, {
      signal: streamController.signal,
    });
    if (!response.ok) throw new Error("MJPEG source unavailable");
    const parser = new MJPEGParser();
    let sequence = 0;
    for await (const chunk of response.body) {
      for (const jpeg of parser.append(Buffer.from(chunk))) {
        sourceHealthy = true;
        const forwarded = relay.push({
          target,
          streamId: sessionID,
          revision: generation,
          sequence: ++sequence,
          data: jpeg.toString("base64"),
        });
        if (forwarded) relay.sources.get(target).state = "device_mjpeg";
      }
    }
  })().catch((error) => {
    void writeFile(
      join(run, "stream-error.json"),
      JSON.stringify({
        error: error.message,
        cause: error.cause?.message,
        code: error.cause?.code,
        stack: error.stack,
      }),
    );
    sourceHealthy = false;
    relay.pause(target, "Device stream unavailable");
    stopped = true;
    generation++;
    refs.clear();
    return { error: error.message };
  });
  if (stopRequested) throw new Error("Stopped during startup");
  media = await startMediaServer({
    run,
    relay,
    lan: !values.smoke,
    command: control,
  });
  await writeFile(
    join(run, "agent-config.json"),
    JSON.stringify({
      kind: "simulator",
      connection: join(run, "viewer-connection.json"),
      surfaceID,
    }),
    { mode: 0o600 },
  );
  const manifest = {
    version: 1,
    surfaces: [
      {
        id: surfaceID,
        title: `Prepared iOS • ${nonce}`,
        workspaceID: values.workspace,
        deviceID: values.udid,
        stream: { ...media.config, target },
      },
    ],
  };
  await writeFile(
    join(run, "surfaces.json"),
    JSON.stringify(manifest, null, 2),
    { mode: 0o600 },
  );
  await writeFile(
    join(run, "run.json"),
    JSON.stringify(
      {
        udid: values.udid,
        sessionID,
        appPID,
        nonce,
        driver,
        mjpegPort,
        booted,
        source: "owned WDA MJPEG",
        surfaceID,
        run,
      },
      null,
      2,
    ),
  );
  for (let i = 0; i < 100 && !sourceHealthy; i++) await pause(100);
  if (!sourceHealthy) throw new Error("No device frames; headset gate blocked");
  const observation = await control({ tool: "surface_observe" });
  await writeFile(
    join(run, "initial.png"),
    Buffer.from(observation.image.data, "base64"),
  );
  if (values.smoke) {
    const increment = observation.elements.find((e) => e.name === "increment");
    if (!increment) throw new Error("Fixture Increment missing");
    await control({ tool: "surface_press", args: { ref: increment.ref } });
    const after = await control({ tool: "surface_observe" });
    const counter = (s) => {
      const e = s.elements.find((e) => e.name === "counter");
      return Number((e?.value ?? e?.label ?? "").match(/\d+$/)?.[0]);
    };
    assert.equal(
      counter(after),
      counter(observation) + 1,
      "Independent AX counter delta",
    );
    await writeFile(
      join(run, "after.png"),
      Buffer.from(after.image.data, "base64"),
    );
    await control({ tool: "surface_stop" });
    let rejected = false;
    try {
      await control({ tool: "surface_press", args: { ref: increment.ref } });
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error("Stop did not reject old action");
    await writeFile(
      join(run, "result.json"),
      JSON.stringify(
        {
          passed: true,
          identity: { udid: values.udid, sessionID, appPID },
          before: observation.elements.filter((e) => e.name === "counter"),
          after: after.elements.filter((e) => e.name === "counter"),
          staleAfterStopRejected: rejected,
          frames: relay.status(),
        },
        null,
        2,
      ),
    );
    console.log(JSON.stringify({ kind: "simulator-smoke-complete", run }));
  } else {
    console.log(
      JSON.stringify({
        kind: "simulator-ready",
        run,
        manifest: join(run, "surfaces.json"),
        connection: join(run, "viewer-connection.json"),
        surfaceID,
        nonce,
      }),
    );
    await runStopped;
  }
} catch (error) {
  await writeFile(join(run, "failure.txt"), error.stack);
  console.error(JSON.stringify({ error: error.message, run }));
  process.exitCode = 1;
} finally {
  stopped = true;
  generation++;
  refs.clear();
  streamController?.abort();
  await streamTask;
  await media?.close();
  if (sessionID)
    await api("DELETE", `/session/${sessionID}`, undefined, 5000).catch(
      () => {},
    );
  if (child?.pid && child.exitCode === null) {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {}
    await Promise.race([exited, pause(3000)]);
    if (child.exitCode === null) {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {}
    }
  }
  const deviceCleanup = child
    ? await stopOwnedDeviceDriver(values.udid, probe)
    : { remaining: [] };
  if (booted)
    execFileSync("xcrun", ["simctl", "shutdown", values.udid], {
      stdio: "ignore",
    });
  await writeFile(
    join(run, "cleanup.json"),
    JSON.stringify({
      at: new Date().toISOString(),
      ownedAppiumExit: child?.exitCode,
      deviceCleanup,
      bootedDeviceShutDown: booted,
    }),
  );
}
