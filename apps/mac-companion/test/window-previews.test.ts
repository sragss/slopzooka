import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, readFile, writeFile, chmod, rm } from "node:fs/promises";
import http, { IncomingMessage } from "node:http";
import { Socket } from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import express from "express";
import { createPeerIngress } from "../src/companion-transport.js";
import { WindowPreviews, windowPresentation } from "../src/window-previews.js";
import { eventLogger } from "../src/log-events.js";

const request = () => new IncomingMessage(new Socket());
test(
  "native catalog, exact identity, fixed binary bridge, source loss and provider recovery",
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
    const server = http.createServer();
    server.on("upgrade", (req, socket, head) => {
      void provider.upgrade(req, socket, head);
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const port = (server.address() as import("node:net").AddressInfo).port;
    let channel: import("node:stream").Duplex | undefined;
    try {
      const catalog = await provider.catalog();
      assert.equal(catalog.state, "ready");
      assert.equal(catalog.sources.length, 1);
      const source = catalog.sources[0];
      assert.equal(
        (await provider.resolve(source.id, request())).contentWidth,
        390,
      );
      await assert.rejects(
        provider.resolve("window:missing", request()),
        /unavailable/,
      );
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
      assert.deepEqual(
        Buffer.concat(received),
        Buffer.concat([Buffer.from([0, 255, 1, 254]), payload]),
      );
      await writeFile(statePath, JSON.stringify({ gone: true }));
      await assert.rejects(
        provider.resolve(source.id, request()),
        /unavailable/,
      );
      await writeFile(
        statePath,
        JSON.stringify({ state: "permissionRequired", gone: true }),
      );
      await assert.rejects(
        provider.resolve(source.id, request()),
        /Screen Recording/,
      );
      await writeFile(
        statePath,
        JSON.stringify({ state: "locked", gone: true }),
      );
      await assert.rejects(provider.resolve(source.id, request()), /Unlock/);
      const closed = once(channel, "close");
      await writeFile(statePath, JSON.stringify({ crash: true }));
      assert.equal((await provider.catalog()).state, "failed");
      await closed;
      await writeFile(statePath, "{}");
      const restarted = await provider.catalog();
      assert.equal(restarted.state, "ready");
      assert.notEqual(restarted.sources[0].id, source.id);
      await assert.rejects(
        provider.resolve(source.id, request()),
        /unavailable/,
      );
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
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await rm(temporary, { recursive: true, force: true });
    }
  },
);

test("native presentation derives Direct from accepting ingress and ignores route-claim headers", async () => {
  const app = express();
  app.get("/", (req, res) =>
    res.json(windowPresentation(req, { state: "ready", sources: [] })),
  );
  const server = createPeerIngress(app, () => {});
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    const port = (server.address() as import("node:net").AddressInfo).port;
    const result = (await (
      await fetch(`http://127.0.0.1:${port}/`)
    ).json()) as any;
    assert.equal(result.available, false);
    assert.equal(result.reasonCode, "presentation_unsupported_on_route");
    const local = request();
    local.headers["x-slopzooka-connection-method"] = "direct";
    assert.equal(
      windowPresentation(local, { state: "ready", sources: [] }).available,
      true,
    );
    assert.equal(
      windowPresentation(local, { state: "locked", sources: [] }).reasonCode,
      "desktop_locked",
    );
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
