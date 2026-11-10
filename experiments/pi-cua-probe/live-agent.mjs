import { readFile, writeFile } from "node:fs/promises";
import { parseArgs, parseEnv } from "node:util";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createModels } from "@earendil-works/pi-ai";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { StdioTransport } from "@earendil-works/pi-mcp";
import { connectHarness } from "./harness.mjs";
import { subprocessEnvironment } from "./runtime.mjs";

const { values } = parseArgs({
  options: {
    config: { type: "string" },
    "prompt-file": { type: "string" },
    "key-file": { type: "string" },
    hold: { type: "boolean" },
  },
});
if (!values.config || !values["prompt-file"])
  throw new Error(
    "Use --config PRIVATE_AGENT_CONFIG --prompt-file FILE [--key-file ENV] [--hold]",
  );
const config = JSON.parse(await readFile(values.config, "utf8"));
const apiKey = values["key-file"]
  ? parseEnv(await readFile(values["key-file"], "utf8")).OPENAI_API_KEY
  : process.env.OPENAI_API_KEY;
if (!apiKey) throw new Error("Use an existing key file; never paste the key");
const models = createModels();
models.setProvider(openaiProvider());
const model = models.getModel("openai", "gpt-6.1-sol");
const toolNames =
  config.kind === "browser"
    ? [
        "browser_observe",
        "browser_click",
        "browser_fill",
        "browser_screenshot",
        "browser_stop",
      ]
    : [
        "surface_status",
        "surface_present",
        "surface_observe",
        "surface_press",
        "surface_fill",
        "surface_swipe",
        "surface_tap",
        "surface_stop",
      ];
if (!config.companion) {
  for (const name of ["surface_status", "surface_present"]) {
    const i = toolNames.indexOf(name);
    if (i >= 0) toolNames.splice(i, 1);
  }
}
const started = Date.now(),
  events = [];
const harness = await connectHarness({
  model,
  maxToolCalls: 40,
  toolNames,
  transport: new StdioTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("../surface-live-probe/mcp.mjs", import.meta.url)),
      resolve(values.config),
    ],
    env: subprocessEnvironment(),
    inheritEnv: false,
  }),
  streamFn: (m, context, options) =>
    models.streamSimple(m, context, {
      ...options,
      apiKey,
      maxRetries: 0,
      maxTokens: 2048,
      reasoning: "low",
    }),
  onEvent: (event) => {
    const row = { elapsedMs: Date.now() - started, ...event };
    events.push(row);
    console.log(JSON.stringify(row));
  },
});
let stopped = false;
const ended = new Promise((r) => {
  for (const signal of ["SIGINT", "SIGTERM"])
    process.once(signal, () => {
      stopped = true;
      void harness.stop();
      r();
    });
});
try {
  await harness.agent.prompt(await readFile(values["prompt-file"], "utf8"));
  const messages = harness.agent.state.messages;
  const artifactPrefix = `agent-${Date.now()}`;
  const artifactDir = dirname(resolve(values.config));
  const transcript = structuredClone(messages);
  let imageIndex = 0;
  for (const message of transcript)
    for (const block of message.content ?? []) {
      if (block.type !== "image" || !block.data) continue;
      const filename = `${artifactPrefix}-image-${++imageIndex}.${block.mimeType === "image/jpeg" ? "jpg" : "png"}`;
      await writeFile(
        join(artifactDir, filename),
        Buffer.from(block.data, "base64"),
        { mode: 0o600 },
      );
      delete block.data;
      block.localArtifact = filename;
    }
  await writeFile(
    join(artifactDir, `${artifactPrefix}-messages.json`),
    JSON.stringify(transcript, null, 2),
    { mode: 0o600 },
  );
  const result = {
    at: new Date().toISOString(),
    elapsedMs: Date.now() - started,
    events,
    model: model.id,
    stopped,
    final: messages.findLast((m) => m.role === "assistant"),
    errors: messages.filter((m) => m.role === "toolResult" && m.isError).length,
    images: messages
      .filter((m) => m.role === "toolResult")
      .flatMap((m) => m.content.filter((p) => p.type === "image")).length,
    transcript: `${artifactPrefix}-messages.json`,
  };
  const file = join(
    dirname(resolve(values.config)),
    `agent-result-${Date.now()}.json`,
  );
  await writeFile(file, JSON.stringify(result, null, 2), { mode: 0o600 });
  console.log(
    JSON.stringify({
      kind: "agent-complete",
      result: file,
      errors: result.errors,
      images: result.images,
      holding: !!values.hold,
    }),
  );
  if (values.hold && !stopped) await ended;
} finally {
  await harness.stop();
}
