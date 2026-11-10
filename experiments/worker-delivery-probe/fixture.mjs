import { createRequire } from "node:module";
import { appendFile, access } from "node:fs/promises";
import { join, resolve } from "node:path";
const require = createRequire(
  new URL("../surface-live-probe/package.json", import.meta.url),
);
const { Server } = require("@modelcontextprotocol/sdk/server/index.js");
const {
  StdioServerTransport,
} = require("@modelcontextprotocol/sdk/server/stdio.js");
const {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} = require("@modelcontextprotocol/sdk/types.js");
const root = resolve(process.argv[2]);
const log = (event) =>
  appendFile(
    join(root, "fixture.jsonl"),
    JSON.stringify({ at: Date.now(), pid: process.pid, ...event }) + "\n",
    { mode: 0o600 },
  );
const server = new Server(
  { name: "worker-delivery-fixture", version: "0.1.0" },
  {
    capabilities: { tools: {} },
    instructions:
      "Disposable fixture. Only use the requested label. Each record is independently logged and is not deduplicated. Never retry an uncertain record.",
  },
);
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "record",
      description:
        "Append one named effect to the disposable test ledger. No other app or file is modified.",
      inputSchema: {
        type: "object",
        properties: { label: { type: "string", pattern: "^[a-z0-9-]{1,80}$" } },
        required: ["label"],
        additionalProperties: false,
      },
    },
    {
      name: "wait_gate",
      description:
        "Wait at a named test gate until the operator releases it. Do not use shell or poll other tools.",
      inputSchema: {
        type: "object",
        properties: { label: { type: "string", pattern: "^[a-z0-9-]{1,80}$" } },
        required: ["label"],
        additionalProperties: false,
      },
    },
    {
      name: "ask_fixture_permission",
      description:
        "Ask the operator for harmless disposable-fixture consent using native MCP elicitation. Does not grant system permissions.",
      inputSchema: {
        type: "object",
        properties: {},
        additionalProperties: false,
      },
    },
  ],
}));
server.setRequestHandler(CallToolRequestSchema, async ({ params }, extra) => {
  const label = params.arguments?.label;
  if (
    params.name !== "ask_fixture_permission" &&
    !/^[a-z0-9-]{1,80}$/.test(label ?? "")
  )
    throw new Error("Invalid label");
  await log({ event: "entered", tool: params.name, label });
  if (params.name === "record") await log({ event: "effect", label });
  else if (params.name === "wait_gate") {
    const deadline = Date.now() + 120000;
    while (true) {
      if (extra.signal.aborted) {
        await log({ event: "cancelled", label });
        throw new Error("Cancelled fixture gate");
      }
      if (Date.now() > deadline) throw new Error("Fixture gate timed out");
      try {
        await access(join(root, `release-${label}`));
        break;
      } catch {}
      await new Promise((r) => setTimeout(r, 50));
    }
    await log({ event: "released", label });
  } else if (params.name === "ask_fixture_permission") {
    const answer = await server.elicitInput({
      mode: "form",
      message: "Disposable worker-delivery fixture: permit one test marker?",
      requestedSchema: {
        type: "object",
        properties: {
          permit: { type: "boolean", title: "Permit fixture marker" },
        },
        required: ["permit"],
      },
    });
    await log({ event: "elicitation", answer });
    return { content: [{ type: "text", text: JSON.stringify(answer) }] };
  } else throw new Error("Unknown fixture tool");
  return {
    content: [{ type: "text", text: JSON.stringify({ ok: true, label }) }],
  };
});
await server.connect(new StdioServerTransport());
