import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, readFile, writeFile, chmod, rm } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import express from "express";
import { createPeerIngress } from "../src/companion-transport.js";
import { WindowPreviews, windowPresentation } from "../src/window-previews.js";
import { eventLogger } from "../src/log-events.js";

for (const direct of [false, true])
  test(
    `native ${direct ? "Direct" : "LAN"} catalog, binary bridge, source loss and provider recovery`,
    { timeout: 15000 },
    async () => {
      const temporary = await mkdtemp(
        path.join(os.tmpdir(), "slz-window-provider-"),
      );
      const statePath = path.join(temporary, "state.json");
      const binary = path.join(temporary, "provider.mjs");
      const script = await readFile(
        new URL("./fixtures/window-provider.mjs", import.meta.url),
        "utf8",
      );
      await writeFile(statePath, "{}");
      await writeFile(
        binary,
        script.replace("'__STATE_FILE__'", JSON.stringify(statePath)),
      );
      await chmod(binary, 0o755);
      const events: any[] = [];
      const provider = new WindowPreviews(
        eventLogger("mac-companion", (event) => events.push(event))(
          "window-previews",
        ),
        binary,
        true,
      );
      const upgrade: import("../src/companion-transport.js").Upgrade = (
        req,
        socket,
        head,
      ) => {
        void provider.upgrade(req, socket, head);
      };
      const app = express();
      const server = direct
        ? createPeerIngress(app, upgrade)
        : http.createServer(app);
      if (!direct) server.on("upgrade", upgrade);
      server.listen(0, "127.0.0.1");
      await once(server, "listening");
      const port = (server.address() as import("node:net").AddressInfo).port;
      let channel: import("node:stream").Duplex | undefined;
      try {
        const catalog = await provider.catalog();
        assert.equal(catalog.state, "ready");
        assert.equal(catalog.sources.length, 1);
        const source = catalog.sources[0];
        assert.equal((await provider.resolve(source.id)).contentWidth, 390);
        await assert.rejects(provider.resolve("window:missing"), /unavailable/);
        channel = await new Promise<import("node:stream").Duplex>(
          (resolve, reject) => {
            const req = http.request({
              host: "127.0.0.1",
              port,
              path: `/api/window-stream/${source.id}`,
              headers: { Connection: "Upgrade", Upgrade: "slz-window-v1" },
            });
            req.once("upgrade", (_res, socket, head) => {
              if (head.length) socket.unshift(head);
              resolve(socket);
            });
            req.once("response", () => reject(new Error("Expected upgrade")));
            req.once("error", reject);
            req.end();
          },
        );
        const received: Buffer[] = [];
        channel.on("data", (data: Buffer) => received.push(data));
        const payload = Buffer.alloc(350_000, 197);
        channel.write(payload);
        const deadline = Date.now() + 3000;
        while (
          Buffer.concat(received).length < payload.length + 4 &&
          Date.now() < deadline
        )
          await new Promise((resolve) => setTimeout(resolve, 10));
        const actual = Buffer.concat(received);
        const expected = Buffer.concat([
          Buffer.from([0, 255, 1, 254]),
          payload,
        ]);
        assert.equal(actual.length, expected.length);
        assert(
          actual.equals(expected),
          "Native bridge preserves every binary byte",
        );
        await writeFile(statePath, JSON.stringify({ gone: true }));
        await assert.rejects(provider.resolve(source.id), /unavailable/);
        await writeFile(
          statePath,
          JSON.stringify({ state: "permissionRequired", gone: true }),
        );
        await assert.rejects(provider.resolve(source.id), /Screen Recording/);
        await writeFile(
          statePath,
          JSON.stringify({ state: "locked", gone: true }),
        );
        await assert.rejects(provider.resolve(source.id), /Unlock/);
        const closed = once(channel, "close");
        await writeFile(statePath, JSON.stringify({ crash: true }));
        assert.equal((await provider.catalog()).state, "failed");
        await closed;
        await writeFile(statePath, "{}");
        const restarted = await provider.catalog();
        assert.equal(restarted.state, "ready");
        assert.notEqual(restarted.sources[0].id, source.id);
        await assert.rejects(provider.resolve(source.id), /unavailable/);
        await writeFile(statePath, JSON.stringify({ malformed: true }));
        assert.equal((await provider.catalog()).state, "failed");
        assert(events.some((event) => event.event === "provider.ready"));
        assert(
          events.every((event) => !JSON.stringify(event).includes("Fixture")),
          "Window titles never enter diagnostic metadata",
        );
      } finally {
        channel?.destroy();
        provider.stop();
        server.closeAllConnections(); // Bound cleanup of unrelated local discovery probes.
        await new Promise<void>((resolve) => server.close(() => resolve()));
        await rm(temporary, { recursive: true, force: true });
      }
    },
  );

test("native availability depends on capture state on every route", () => {
  assert.equal(
    windowPresentation({ state: "ready", sources: [] }).available,
    true,
  );
  for (const [state, reason] of [
    ["locked", "desktop_locked"],
    ["permissionRequired", "permission_required"],
    ["failed", "provider_unavailable"],
  ] as const) {
    const availability = windowPresentation({ state, sources: [] });
    assert.equal(availability.available, false);
    assert.equal(availability.reasonCode, reason);
  }
});
