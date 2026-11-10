import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { FrameRelay, packet } from "../media.mjs";
class Peer extends EventEmitter {
  writableLength = 0;
  destroyed = false;
  writes = [];
  write(data) {
    this.writes.push(data);
    this.writableLength = data.length;
  }
  destroy() {
    this.destroyed = true;
    this.emit("close");
  }
}
const frame = (target = "a", sequence = 1, streamId = "one", revision = 0) => ({
  target,
  sequence,
  streamId,
  revision,
  data: Buffer.from("jpeg-fixture").toString("base64"),
});
test("media requires explicit incarnation, monotonic sequence and current document", () => {
  const r = new FrameRelay();
  r.add("a", "A");
  r.bind("a", "one");
  assert(r.push(frame()));
  assert(!r.push(frame()));
  assert(!r.push(frame("b", 2)));
  assert(r.push(frame("a", 2, "one", 2)));
  assert(!r.push(frame("a", 3, "one", 1)));
  r.bind("a", "two");
  assert(!r.push(frame("a", 4)));
  assert(r.push(frame("a", 1, "two")));
  r.pause("a", "stopped");
  assert(!r.push(frame("a", 2, "two")));
  assert.equal(r.sources.get("a").latest, null);
});
test("slow receiver never grows an image queue; revocation disconnects it, peer source survives", () => {
  const r = new FrameRelay();
  r.add("a", "A");
  r.add("b", "B");
  r.bind("a", "one");
  r.bind("b", "one");
  const p = new Peer();
  r.subscribe("a", p);
  r.push(frame());
  for (let i = 2; i < 100; i++) r.push(frame("a", i));
  assert.equal(p.writes.length, 1);
  assert.equal(r.sources.get("a").drops, 98);
  r.pause("a", "stopped");
  assert(p.destroyed);
  assert(r.push(frame("b")));
});
test("native receiver framing and limits", () => {
  const p = packet({ kind: "jpeg", generation: 3 }, Buffer.from("abc"));
  assert.equal(p.readUInt32BE(4), 3);
  assert.equal(p.subarray(8 + p.readUInt32BE(0)).toString(), "abc");
  assert.throws(() => packet({}, Buffer.alloc(8 * 1024 * 1024 + 1)));
});
