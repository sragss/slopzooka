// Test MCP server only: a visual card and a single answer, not a browser/CUA substitute.
import { createInterface } from "node:readline";
import { deflateSync } from "node:zlib";

function chunk(type, bytes) {
  const payload = Buffer.concat([Buffer.from(type), bytes]);
  let crc = 0xffffffff;
  for (const byte of payload) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++)
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  const size = Buffer.alloc(4);
  size.writeUInt32BE(bytes.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([size, payload, checksum]);
}
const header = Buffer.alloc(13);
header.writeUInt32BE(64, 0);
header.writeUInt32BE(64, 4);
header[8] = 8;
header[9] = 2;
const pixels = Buffer.alloc(64 * (1 + 64 * 3));
for (let row = 0; row < 64; row++) {
  for (let col = 0; col < 64; col++) pixels[row * 193 + 1 + col * 3] = 240;
}
export const card = Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  chunk("IHDR", header),
  chunk("IDAT", deflateSync(pixels)),
  chunk("IEND", Buffer.alloc(0)),
]).toString("base64");

export const fixtureTool = {
  name: "visual_fixture",
  description:
    "Disposable visual transport test. Observe a card, then submit its color once. This does not control any app.",
  inputSchema: {
    type: "object",
    properties: {
      action: { type: "string", enum: ["observe", "answer"] },
      color: { type: "string" },
    },
    required: ["action"],
    additionalProperties: false,
  },
};

export function fixtureServer(send, { onCall = () => {} } = {}) {
  let observed = false;
  let answers = 0;
  return async (message) => {
    if (message.id === undefined) return;
    const reply = (result) => send({ jsonrpc: "2.0", id: message.id, result });
    if (message.method === "initialize")
      return reply({
        protocolVersion: message.params.protocolVersion,
        serverInfo: { name: "slz-visual-fixture-NOT-CUA", version: "0.1.0" },
        capabilities: { tools: {} },
        instructions:
          "First observe the visual card. Infer its color from the image, then answer exactly once.",
      });
    if (message.method === "tools/list") return reply({ tools: [fixtureTool] });
    if (message.method === "tools/call") {
      onCall(message);
      const args = message.params.arguments;
      if (
        message.params.name === fixtureTool.name &&
        args.action === "observe"
      ) {
        observed = true;
        return reply({
          content: [
            {
              type: "text",
              text: "Visual observation attached. Submit the color you see.",
            },
            { type: "image", mimeType: "image/png", data: card },
          ],
          structuredContent: { observed: true },
        });
      }
      if (
        message.params.name === fixtureTool.name &&
        args.action === "answer"
      ) {
        answers++;
        const passed =
          observed && answers === 1 && args.color?.toLowerCase() === "red";
        return reply({
          isError: !passed,
          content: [
            { type: "text", text: JSON.stringify({ passed, answers }) },
          ],
        });
      }
      return reply({
        isError: true,
        content: [{ type: "text", text: "Unknown fixture action" }],
      });
    }
    return send({
      jsonrpc: "2.0",
      id: message.id,
      error: { code: -32601, message: "Not implemented by test fixture" },
    });
  };
}

if (
  process.argv[1] &&
  import.meta.url === new URL(process.argv[1], "file:").href
) {
  const handle = fixtureServer((message) =>
    process.stdout.write(`${JSON.stringify(message)}\n`),
  );
  createInterface({ input: process.stdin }).on("line", (line) => {
    void handle(JSON.parse(line));
  });
}
