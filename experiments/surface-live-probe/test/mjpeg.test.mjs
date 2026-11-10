import test from "node:test";
import assert from "node:assert/strict";
import { MJPEGParser } from "../mjpeg.mjs";
test("WDA multipart survives byte splits/coalescing and rejects oversized or invalid image lengths", () => {
  const jpeg = Buffer.from([255, 216, 1, 2, 255, 217]);
  const packet = Buffer.concat([
    Buffer.from(
      `--boundary\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`,
    ),
    jpeg,
    Buffer.from("\r\n\r\n"),
  ]);
  const p = new MJPEGParser(),
    frames = [];
  for (const byte of Buffer.concat([packet, packet]))
    frames.push(...p.append(Buffer.from([byte])));
  assert.equal(frames.length, 2);
  assert.deepEqual(frames[0], jpeg);
  assert.throws(() =>
    new MJPEGParser().append(
      Buffer.from("--b\r\nContent-Length: 9000000\r\n\r\n"),
    ),
  );
  assert.throws(() =>
    new MJPEGParser().append(Buffer.from("--b\r\nContent-Length: 2\r\n\r\nxx")),
  );
});
