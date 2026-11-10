import { receiveMedia } from "./receive-media.mjs";
import assert from "node:assert/strict";
import { writeFile, appendFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { connectBridge } from "./bridge.mjs";
import { FrameRelay, startMediaServer } from "./media.mjs";
import { connectHumanFixture } from "./test-driver.mjs";

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function ref(state, role, name) {
  const rows = state.elements.filter(
    (e) => e.role === role && e.name === name && e.ref,
  );
  assert.equal(rows.length, 1, `${role}: ${name}`);
  return rows[0].ref;
}
export async function runStreaming({
  bridge,
  socketPath,
  origin,
  run,
  endpoint,
  fixtureEvents,
  headed,
  serve,
}) {
  const relay = new FrameRelay(),
    clients = {},
    targets = {},
    results = [];
  const nonce = randomUUID().slice(0, 8);
  const durationArg = process.argv.indexOf("--stream-seconds");
  const duration =
    durationArg < 0 ? 5000 : Number(process.argv[durationArg + 1]) * 1000;
  if (!Number.isFinite(duration) || duration < 1000 || duration > 600000)
    throw new Error("--stream-seconds must be between 1 and 600");
  const phases = process.argv.includes("--phases");
  let media, human;
  const receivers = [];
  const receive = (event) => {
    if (event.event === "media-frame") relay.push(event);
    if (["revoked", "media-stopped"].includes(event.event))
      relay.pause(event.target, event.reason ?? "stopped");
  };
  const disconnected = () => {
    for (const id of relay.sources.keys())
      relay.pause(id, "bridge disconnected");
  };
  bridge.events.on("event", receive);
  bridge.events.on("disconnected", disconnected);
  async function record(name, fn) {
    const start = performance.now();
    try {
      const detail = await fn();
      const row = {
        name,
        passed: true,
        elapsedMs: performance.now() - start,
        detail,
      };
      results.push(row);
      console.log(JSON.stringify(row));
    } catch (error) {
      results.push({ name, passed: false, error: error.message });
      throw error;
    } finally {
      await writeFile(
        join(run, "stream-results.json"),
        JSON.stringify(
          { headed, nonce, results, stats: relay.status() },
          null,
          2,
        ),
      );
    }
  }
  async function observe(slot) {
    return clients[slot].call("browser_observe", {
      target: targets[slot].target,
    });
  }
  async function click(slot, name) {
    const state = await observe(slot);
    return clients[slot].call("browser_click", {
      target: targets[slot].target,
      ref: ref(state, "button", name),
    });
  }
  async function sample(name, activeSlots) {
    await record(name, async () => {
      const before = relay.status(),
        started = performance.now();
      const receiverBytes = receivers.map((r) => r.state.bytes);
      await pause(duration);
      const seconds = (performance.now() - started) / 1000;
      return relay.status().map((s, i) => {
        assert.equal(receivers[i].state.errors.length, 0);
        const frames = s.frames - before[i].frames;
        if (activeSlots.includes(i === 0 ? "a" : "b"))
          assert(frames >= 10, "Active source stalled");
        return {
          slot: i === 0 ? "a" : "b",
          seconds,
          frames,
          fps: frames / seconds,
          jpegBytes: s.bytes - before[i].bytes,
          framedIngressBytes: s.ingressBytes - before[i].ingressBytes,
          receiverBytes: receivers[i].state.bytes - receiverBytes[i],
          drops: s.drops - before[i].drops,
          human: null,
        };
      });
    });
  }
  try {
    for (const slot of ["a", "b"]) {
      clients[slot] = await connectBridge(socketPath);
      targets[slot] = await clients[slot].call("browser_open", {
        url: `${origin}/${slot}?nonce=${nonce}`,
      });
      relay.add(
        targets[slot].target,
        `Browser ${slot.toUpperCase()} • ${nonce}`,
      );
      const stream = await clients[slot].call("browser_stream_start", {
        target: targets[slot].target,
      });
      relay.bind(targets[slot].target, stream.streamId);
    }
    human = await connectHumanFixture(endpoint, `${origin}/human`);
    await human.type("human-keeps-typing");
    const allowed = new Set([
      "browser_observe",
      "browser_click",
      "browser_fill",
      "browser_screenshot",
      "browser_stream_stop",
      "browser_stream_start",
      "browser_stop",
    ]);
    media = await startMediaServer({
      run,
      relay,
      lan: serve,
      command: async ({ slot, tool, args = {} }) => {
        if (!clients[slot] || !allowed.has(tool))
          throw new Error("Unknown fixture slot/tool");
        if (args.target && args.target !== targets[slot].target)
          throw new Error("Foreign target");
        const value = await clients[slot].call(tool, {
          ...args,
          ...(tool === "browser_stop" ? {} : { target: targets[slot].target }),
        });
        if (tool === "browser_stream_start")
          relay.bind(targets[slot].target, value.streamId);
        await appendFile(
          join(run, "stream-commands.jsonl"),
          JSON.stringify({ at: Date.now(), slot, tool }) + "\n",
        );
        return value;
      },
    });
    await writeFile(
      join(run, "stream-manifest.json"),
      JSON.stringify(
        {
          nonce,
          origin,
          socketPath,
          targets,
          headed,
          source:
            "Page.startScreencast JPEG quality65 max1280x960 everyNthFrame3",
          endpoint,
          viewerConnection: join(run, "viewer-connection.json"),
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
    for (const target of Object.values(targets))
      receivers.push(await receiveMedia(media.config, run, target.target));
    if (phases) {
      await clients.b.call("browser_stream_stop", { target: targets.b.target });
      await sample("one_animated_source", ["a"]);
      const stream = await clients.b.call("browser_stream_start", {
        target: targets.b.target,
      });
      relay.bind(targets.b.target, stream.streamId);
    }
    await sample("two_animated_sources", ["a", "b"]);
    await record("two_background_sources", async () => {
      for (let i = 0; i < receivers.length; i++) {
        const { state } = receivers[i];
        assert.equal(state.errors.length, 0);
        assert(state.frames >= 10);
        await writeFile(
          join(run, `received-${i === 0 ? "a" : "b"}.jpg`),
          state.jpeg,
        );
      }
      const stats = relay.status();
      assert(
        stats.every((s) => s.frames >= 10),
        `Insufficient fresh frames: ${stats.map((s) => s.frames)}`,
      );
      for (const s of stats) {
        const p = relay.sources.get(s.id).latest;
        const n = p.readUInt32BE(0);
        await writeFile(join(run, `${s.id}.jpg`), p.subarray(8 + n));
      }
      return stats.map(({ intervalsMs, ...s }) => s);
    });
    if (phases) {
      for (const slot of ["a", "b"]) await click(slot, "Pause animation");
      await pause(1000);
      await sample("two_static_sources", []);
      for (const slot of ["a", "b"]) await click(slot, "Resume animation");
    }
    await record("input_and_foreground_independence", async () => {
      for (const slot of ["a", "b"]) {
        const state = await observe(slot);
        await clients[slot].call("browser_fill", {
          target: targets[slot].target,
          ref: ref(state, "textbox", "Workspace label"),
          text: `${slot}-${nonce}`,
        });
        await click(slot, "Save label");
        await click(slot, "Increment");
        await click(slot, "Increment");
      }
      await pause(500);
      for (const slot of ["a", "b"])
        assert.equal(
          fixtureEvents.filter(
            (e) => e.fixture === `/${slot}` && e.action === "increment",
          ).length,
          2,
        );
      const state = await human.state();
      assert.equal(state.value, "human-keeps-typing");
      assert.equal(state.caret, "human-keeps-typing".length);
      const tabs = await clients.a.call("browser_tabs");
      assert(tabs.find((t) => t.url === `${origin}/human`).active);
      for (let i = 0; i < receivers.length; i++)
        await writeFile(
          join(run, `received-after-input-${i === 0 ? "a" : "b"}.jpg`),
          receivers[i].state.jpeg,
        );
      return { human: state, activeTabUnchanged: true, fixtureEffects: 6 };
    });
    for (const slot of ["a", "b"])
      await writeFile(
        join(run, `agent-${slot}.json`),
        JSON.stringify({
          kind: "browser",
          slot,
          connection: join(run, "viewer-connection.json"),
        }),
        { mode: 0o600 },
      );
    if (serve) {
      console.log(
        JSON.stringify({
          kind: "stream-ready",
          run,
          connectionFile: join(run, "viewer-connection.json"),
          targets,
          nonce,
          instructions:
            "Private viewer connection is in the file. SIGINT ends only this disposable browser/stream run.",
        }),
      );
      await new Promise((resolve) => {
        process.once("SIGINT", resolve);
        process.once("SIGTERM", resolve);
      });
    } else {
      await record("stop_one_source_peer_continues", async () => {
        const before = relay.sources.get(targets.b.target).frames;
        await clients.a.call("browser_stop");
        await pause(1500);
        assert.equal(relay.sources.get(targets.a.target).latest, null);
        assert(relay.sources.get(targets.b.target).frames > before);
        await click("b", "Increment");
        return { aInvalidated: true, bContinued: true };
      });
    }
  } finally {
    bridge.events.off("event", receive);
    bridge.events.off("disconnected", disconnected);
    for (const client of Object.values(clients)) client.close();
    human?.close();
    for (const receiver of receivers) receiver.close();
    await media?.close();
    await writeFile(
      join(run, "stream-results.json"),
      JSON.stringify(
        { headed, nonce, results, stats: relay.status() },
        null,
        2,
      ),
    );
  }
}
