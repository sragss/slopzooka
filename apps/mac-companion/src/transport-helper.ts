/** Private, bounded IPC from the native ingress. Its owner supplies the logger;
 * no helper-specific files, collector, or arbitrary text forwarding. */
export type TransportHelperMessage =
  | { type: "ready"; port: number }
  | { type: "observation"; event: string; fields: Record<string, string> };
const events = new Set([
  "listener.ready",
  "listener.failed",
  "listener.stopped",
  "stream.failed",
  "peer.admitted",
]);
const fields = new Set([
  "stage",
  "connectionId",
  "durationMs",
  "errorDomain",
  "errorCode",
  "opened",
  "failed",
  "active",
  "interfaceName",
  "interfaceIndex",
]);

export class TransportHelperDecoder {
  private pending = Buffer.alloc(0);
  constructor(
    private readonly receive: (message: TransportHelperMessage) => void,
  ) {}

  push(chunk: Buffer): void {
    // Bound the unfinished frame, including a chunk with no newline. Never log
    // malformed helper output; errors contain no raw bytes or identity paths.
    let offset = 0;
    while (offset < chunk.length) {
      const newline = chunk.indexOf(10, offset);
      const end = newline === -1 ? chunk.length : newline;
      if (this.pending.length + end - offset > 4096)
        throw new Error("Transport helper frame exceeds limit");
      this.pending = Buffer.concat([this.pending, chunk.subarray(offset, end)]);
      offset = end + 1;
      if (newline === -1) break;
      const frame = this.pending;
      this.pending = Buffer.alloc(0);
      this.receive(this.decode(frame));
    }
  }

  private decode(frame: Buffer): TransportHelperMessage {
    let parsed: unknown;
    try {
      parsed = JSON.parse(frame.toString("utf8"));
    } catch {
      throw new Error("Invalid transport helper frame");
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
      throw new Error("Unsupported transport helper frame");
    const value = parsed as Record<string, unknown>;
    if (
      value.version === 1 &&
      value.type === "ready" &&
      typeof value.port === "number" &&
      Number.isInteger(value.port) &&
      value.port > 0 &&
      value.port <= 65535
    )
      return { type: "ready", port: value.port };
    if (
      value.version === 1 &&
      value.type === "observation" &&
      typeof value.event === "string" &&
      events.has(value.event) &&
      value.fields &&
      typeof value.fields === "object" &&
      !Array.isArray(value.fields) &&
      Object.entries(value.fields).every(
        ([key, item]) =>
          fields.has(key) && typeof item === "string" && item.length <= 256,
      )
    )
      return {
        type: "observation",
        event: value.event,
        fields: value.fields as Record<string, string>,
      };
    throw new Error("Unsupported transport helper frame");
  }
}
