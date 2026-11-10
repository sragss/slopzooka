// Independent JPEGs with Content-Length, as emitted by the pinned WDA server.
// Bound framing before allocation; retain no history after yielding a frame.
export class MJPEGParser {
  buffer = Buffer.alloc(0);
  append(data) {
    if (this.buffer.length + data.length > 16 * 1024 * 1024)
      throw new Error("MJPEG buffer exceeded");
    this.buffer = Buffer.concat([this.buffer, data]);
    const frames = [];
    while (true) {
      while (this.buffer[0] === 13 && this.buffer[1] === 10)
        this.buffer = this.buffer.subarray(2);
      const end = this.buffer.indexOf("\r\n\r\n");
      if (end < 0) break;
      if (end > 8192) throw new Error("MJPEG header exceeded");
      const header = this.buffer.subarray(0, end).toString("ascii");
      const match = /content-length:\s*(\d+)/i.exec(header);
      if (!match)
        throw new Error(
          `Missing MJPEG frame length: ${JSON.stringify(header.slice(0, 200))}`,
        );
      const size = Number(match[1]);
      if (!size || size > 8 * 1024 * 1024)
        throw new Error("Invalid MJPEG frame length");
      if (this.buffer.length < end + 4 + size) break;
      const jpeg = this.buffer.subarray(end + 4, end + 4 + size);
      if (
        jpeg[0] !== 255 ||
        jpeg[1] !== 216 ||
        jpeg.at(-2) !== 255 ||
        jpeg.at(-1) !== 217
      )
        throw new Error("Invalid JPEG source");
      frames.push(jpeg);
      this.buffer = this.buffer.subarray(end + 4 + size);
    }
    return frames;
  }
}
