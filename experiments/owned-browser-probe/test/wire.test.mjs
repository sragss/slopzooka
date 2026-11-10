import { test } from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { encode, receive } from "../wire.mjs";

test("native frames survive chunk splitting, coalescing, unicode and image-sized replies", () => {
  const stream = new PassThrough();
  const expected = [
    { text: "🎹 café" },
    { image: "a".repeat(1_200_000) },
    { done: true },
  ];
  const received = [];
  receive(
    stream,
    (row) => received.push(row),
    (error) => {
      throw error;
    },
  );
  const bytes = Buffer.concat(
    expected.map((row) => encode(row, 8 * 1024 * 1024)),
  );
  for (let i = 0; i < bytes.length; i += 317)
    stream.write(bytes.subarray(i, i + 317));
  assert.deepEqual(received, expected);
});

test("oversized host-to-Chrome message and hostile announced size are rejected", () => {
  assert.throws(() => encode({ text: "a".repeat(1024 * 1024) }), /limit/);
  const stream = new PassThrough();
  let error;
  receive(
    stream,
    () => assert.fail("must not decode"),
    (value) => {
      error = value;
    },
  );
  stream.write(Buffer.from([255, 255, 255, 255]));
  assert.match(error.message, /frame length/);
  assert.equal(stream.destroyed, true);
});
