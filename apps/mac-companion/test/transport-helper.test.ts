import assert from "node:assert/strict";
import test from "node:test";
import {
  TransportHelperDecoder,
  type TransportHelperMessage,
} from "../src/transport-helper.js";
import { eventLogger } from "../src/log-events.js";

test("helper IPC tolerates fragmentation, accepts only bounded typed metadata, and uses the central logger", () => {
  const received: TransportHelperMessage[] = [];
  const decoder = new TransportHelperDecoder((message) =>
    received.push(message),
  );
  const ready = '{"version":1,"type":"ready","port":12345}\n';
  decoder.push(Buffer.from(ready.slice(0, 18)));
  assert.equal(received.length, 0);
  decoder.push(Buffer.from(ready.slice(18) + ready));
  assert.deepEqual(received, [
    { type: "ready", port: 12345 },
    { type: "ready", port: 12345 },
  ]);
  const records: any[] = [];
  const log = eventLogger("mac-companion", (event) => records.push(event))(
    "transport",
    { hostId: "fixture" },
  );
  const logging = new TransportHelperDecoder((message) => {
    if (message.type === "observation") log.warn(message.event, message.fields);
  });
  logging.push(
    Buffer.from(
      JSON.stringify({
        version: 1,
        type: "observation",
        event: "stream.failed",
        fields: { stage: "outgoing", errorCode: "-9807" },
      }) + "\n",
    ),
  );
  assert.equal(records[0].component, "transport");
  assert.equal(records[0].fields.hostId, "fixture");
  assert.equal(records[0].fields.errorCode, "-9807");
  logging.push(
    Buffer.from(
      JSON.stringify({
        version: 1,
        type: "observation",
        event: "peer.admitted",
        fields: { interfaceName: "fixture-peer", interfaceIndex: "17" },
      }) + "\n",
    ),
  );
  assert.equal(records[1].event, "peer.admitted");
  assert.equal(records[1].fields.interfaceName, "fixture-peer");
  for (const bad of [
    "secret-invalid-json",
    JSON.stringify({ version: 1, type: "ready", port: -1 }),
    JSON.stringify({ version: 2, type: "ready", port: 12345 }),
    JSON.stringify({
      version: 1,
      type: "observation",
      event: "raw-text",
      fields: {},
    }),
    JSON.stringify({
      version: 1,
      type: "observation",
      event: "stream.failed",
      fields: { payload: "private" },
    }),
    JSON.stringify({
      version: 1,
      type: "observation",
      event: "stream.failed",
      fields: { stage: "x".repeat(257) },
    }),
  ]) {
    assert.throws(
      () =>
        new TransportHelperDecoder(() => assert.fail()).push(
          Buffer.from(bad + "\n"),
        ),
      /^(Error: Invalid|Error: Unsupported) transport helper frame$/,
    );
  }
  const oversized = new TransportHelperDecoder(() => assert.fail());
  oversized.push(Buffer.alloc(4096, 32));
  assert.throws(
    () => oversized.push(Buffer.from(" \n")),
    /frame exceeds limit/,
  );
  assert.throws(
    () =>
      new TransportHelperDecoder(() => assert.fail()).push(
        Buffer.alloc(1024 * 1024, 32),
      ),
    /frame exceeds limit/,
  );
});
