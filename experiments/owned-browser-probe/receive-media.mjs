import https from "node:https";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

// Independent receiver for Mac preflight; uses exactly the Vision wire format.
export async function receiveMedia(config, run, target) {
  const ca = await readFile(join(run, "media-cert.pem"));
  const state = {
    frames: 0,
    bytes: 0,
    generation: -1,
    sequence: 0,
    jpeg: null,
    errors: [],
  };
  let buffer = Buffer.alloc(0),
    closed = false;
  const req = https.request({
    host: "127.0.0.1",
    port: config.port,
    path: `/stream/${target}`,
    ca,
    headers: { Authorization: `Bearer ${config.token}` },
    checkServerIdentity: (_host, peer) =>
      peer.fingerprint256?.replaceAll(":", "").toLowerCase() ===
      config.fingerprint
        ? undefined
        : new Error("Wrong certificate"),
  });
  req.on("response", (res) => {
    if (res.statusCode !== 200) {
      state.errors.push(`HTTP ${res.statusCode}`);
      res.destroy();
      return;
    }
    res.on("error", (error) => {
      if (!closed) state.errors.push(error.message);
    });
    res.on("data", (data) => {
      try {
        state.bytes += data.length;
        if (buffer.length + data.length > 17 * 1024 * 1024)
          throw new Error("Receiver buffer exceeded");
        buffer = Buffer.concat([buffer, data]);
        while (buffer.length >= 8) {
          const m = buffer.readUInt32BE(0),
            n = buffer.readUInt32BE(4);
          if (!m || m > 65536 || n > 8 * 1024 * 1024)
            throw new Error("Invalid packet");
          if (buffer.length < 8 + m + n) break;
          const h = JSON.parse(buffer.subarray(8, 8 + m)),
            payload = buffer.subarray(8 + m, 8 + m + n);
          if (h.generation !== state.generation) {
            state.generation = h.generation;
            state.jpeg = null;
            state.sequence = 0;
          }
          if (h.kind === "jpeg") {
            if (
              h.target !== target ||
              h.sequence <= state.sequence ||
              payload[0] !== 255 ||
              payload[1] !== 216
            )
              throw new Error("Wrong-target, out-of-order or invalid image");
            state.frames++;
            state.sequence = h.sequence;
            state.jpeg = Buffer.from(payload);
          } else if (h.kind === "paused") state.jpeg = null;
          buffer = buffer.subarray(8 + m + n);
        }
      } catch (error) {
        state.errors.push(error.message);
        res.destroy();
      }
    });
  });
  req.on("error", (error) => {
    if (!closed) state.errors.push(error.message);
  });
  req.end();
  return {
    state,
    close() {
      closed = true;
      req.destroy();
    },
  };
}
