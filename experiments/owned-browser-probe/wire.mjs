import { endianness } from "node:os";

// Use the same bounded framing on the private socket and Chrome's stdio pipe.
const littleEndian = endianness() === "LE";
export function encode(message, limit = 1024 * 1024) {
  const body = Buffer.from(JSON.stringify(message));
  if (body.length > limit) throw new Error("Message exceeds transport limit");
  const header = Buffer.alloc(4);
  if (littleEndian) header.writeUInt32LE(body.length);
  else header.writeUInt32BE(body.length);
  return Buffer.concat([header, body]);
}

export function receive(stream, onMessage, onError, limit = 8 * 1024 * 1024) {
  let buffered = Buffer.alloc(0);
  stream.on("data", (chunk) => {
    try {
      buffered = Buffer.concat([buffered, chunk]);
      while (buffered.length >= 4) {
        const size = littleEndian
          ? buffered.readUInt32LE(0)
          : buffered.readUInt32BE(0);
        if (!size || size > limit) throw new Error("Invalid frame length");
        if (buffered.length < size + 4) break;
        const message = JSON.parse(buffered.subarray(4, size + 4));
        buffered = buffered.subarray(size + 4);
        onMessage(message);
      }
    } catch (error) {
      buffered = Buffer.alloc(0);
      stream.destroy();
      onError(error);
    }
  });
}

export function send(stream, message, limit) {
  // A slow consumer is a disconnected consumer in this bounded experiment.
  if (stream.destroyed || stream.writableLength > 16 * 1024 * 1024)
    throw new Error("Transport unavailable or backpressured");
  stream.write(encode(message, limit));
}
