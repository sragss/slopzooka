import { readFile, mkdir, writeFile } from "node:fs/promises";
import { parseArgs, parseEnv } from "node:util";
import { fileURLToPath } from "node:url";
import { createModels } from "@earendil-works/pi-ai";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { StdioTransport } from "@earendil-works/pi-mcp";
import { connectHarness } from "./harness.mjs";
import {
  codexRuntime,
  subprocessEnvironment,
  isFixturePermission,
} from "./runtime.mjs";

const { values } = parseArgs({
  options: {
    target: { type: "string", default: "fixture" },
    provider: { type: "string", default: "openai" },
    model: { type: "string" },
    "key-file": { type: "string" },
    check: { type: "boolean", default: false },
    "allow-fixture": { type: "boolean", default: false },
  },
});
if (!["fixture", "browser", "computer"].includes(values.target))
  throw new Error("Invalid target");
if (!["openai", "anthropic"].includes(values.provider))
  throw new Error("Use openai or anthropic");
const keyName =
  values.provider === "anthropic" ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY";
// Parse, never source, an env file. Only this variable is consumed; never export it.
const apiKey = values["key-file"]
  ? parseEnv(await readFile(values["key-file"], "utf8"))[keyName]
  : process.env[keyName];
if (!apiKey && !values.check)
  throw new Error(
    `Set ${keyName} or pass --key-file PATH (never paste a key argument)`,
  );
const models = createModels();
models.setProvider(
  values.provider === "anthropic" ? anthropicProvider() : openaiProvider(),
);
const model = models.getModel(
  values.provider,
  values.model ??
    (values.provider === "anthropic" ? "claude-opus-5-5" : "gpt-6.1-sol"),
);
if (!model) throw new Error("Model is absent from the pinned Pi catalog");
const config =
  values.target === "fixture"
    ? {
        transport: new StdioTransport({
          command: process.execPath,
          args: [fileURLToPath(new URL("./fixture.mjs", import.meta.url))],
          env: subprocessEnvironment(),
          inheritEnv: false,
        }),
        toolNames: ["visual_fixture"],
        metadata: { surface: "synthetic image fixture, not computer use" },
      }
    : await codexRuntime(values.target);
const events = [];
const started = new Date();
const harness = await connectHarness({
  ...config,
  model,
  approveElicitation:
    values["allow-fixture"] && values.target === "computer"
      ? isFixturePermission
      : undefined,
  streamFn: (m, context, options) =>
    models.streamSimple(m, context, {
      ...options,
      apiKey,
      maxRetries: 0,
      maxTokens: 2048,
      reasoning: "low",
    }),
  onEvent: (event) => {
    const row = { elapsedMs: Date.now() - started.getTime(), ...event };
    events.push(row);
    console.log(JSON.stringify(row));
  },
});
const stop = () => {
  void harness.stop();
};
let firstToolDispatchMs;
harness.agent.subscribe((event) => {
  if (event.type === "tool_execution_start")
    firstToolDispatchMs ??= Date.now() - started.getTime();
});
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
try {
  const prompt =
    values.target === "fixture"
      ? "Run the disposable visual fixture: observe the card, use its image to identify its color, submit one answer, and report the actual verdict. This only tests the Pi/MCP/image loop."
      : values.target === "browser"
        ? 'Initialize Google Chrome with exactly one js call: await cua.getBrowser({id:"chrome"}); . This is a read-only connection test. Do not create or claim tabs. On any access/initialization failure, stop and report the exact error. Do not reset/retry or try another backend.'
        : values["allow-fixture"]
          ? "Use only the disposable native app dev.slopzooka.codex-runtime-fixture. Start by selecting it with cua.getApp, then read its returned guidance and current UI. Enter pi-direct in Probe input, click Increment exactly twice, verify Counter: 2 and the entered text, and capture a screenshot. Do not touch any other app. On initialization/access failure stop and report the exact error. Complete within eight tool calls. Report only what you verified."
          : 'Initialize the disposable native fixture with exactly one js call: await cua.getApp("dev.slopzooka.codex-runtime-fixture"); . This is a read-only connection test. Do not control other apps or request permission changes. On any initialization failure, stop and report the exact error. Do not reset/retry.';
  let connectionCheck;
  if (values.check) {
    // Deliberately no model request: isolate the MCP/runtime boundary from API auth.
    const name = values.target === "fixture" ? "visual_fixture" : "js";
    const args =
      values.target === "fixture"
        ? { action: "observe" }
        : {
            code:
              values.target === "browser"
                ? 'await cua.getBrowser({id:"chrome"});'
                : 'await cua.getApp("dev.slopzooka.codex-runtime-fixture");',
            title: "Read-only independent runtime connection check",
            timeout_ms: 10_000,
          };
    const result = await harness.agent.state.tools
      .find((tool) => tool.name === name)
      .execute("connection-check", args, new AbortController().signal);
    connectionCheck = {
      isError: !!result.isError,
      contentTypes: result.content.map((part) => part.type),
      // Do not save private inventories or images. Error text is diagnostic only.
      errors: result.isError
        ? result.content
            .filter((part) => part.type === "text")
            .map((part) => part.text)
            .filter((text) => !text.startsWith("##"))
            .map((text) => text.slice(0, 2500))
        : [],
    };
  } else {
    await harness.agent.prompt(prompt);
  }
  const messages = harness.agent.state.messages;
  const last = messages.findLast((message) => message.role === "assistant");
  const result = {
    startedAt: started.toISOString(),
    elapsedMs: Date.now() - started.getTime(),
    model: model.id,
    provider: values.provider,
    reasoning: "low",
    firstToolDispatchMs,
    target: values.target,
    runtime: config.metadata,
    mcp: harness.metadata,
    modelInvoked: !values.check,
    connectionCheck,
    events,
    final: last?.content
      .filter((part) => part.type === "text")
      .map((part) => part.text)
      .join("\n"),
    stopReason: last?.stopReason,
    modelError: last?.errorMessage,
    unavailable: harness.unavailable,
    toolErrors: messages.filter(
      (message) => message.role === "toolResult" && message.isError,
    ).length,
    // Keep actual token counts; list-price estimates are not billing receipts.
    modelRequests: messages
      .filter((message) => message.role === "assistant")
      .map((message) => ({
        stopReason: message.stopReason,
        usage: message.usage,
      })),
  };
  const outputDir = new URL("./build/", import.meta.url);
  await mkdir(outputDir, { recursive: true });
  const images = messages
    .filter((message) => message.role === "toolResult")
    .flatMap((message) =>
      message.content.filter((part) => part.type === "image"),
    );
  result.modelVisibleImages = images.length;
  const lastImage = images.at(-1);
  if (lastImage && ["image/png", "image/jpeg"].includes(lastImage.mimeType)) {
    const extension = lastImage.mimeType === "image/png" ? "png" : "jpg";
    const screenshot = new URL(
      `${started.toISOString().replaceAll(":", "-")}-${values.target}.${extension}`,
      outputDir,
    );
    await writeFile(screenshot, Buffer.from(lastImage.data, "base64"));
    result.lastImageArtifact = fileURLToPath(screenshot);
  }
  const output = new URL(
    `${started.toISOString().replaceAll(":", "-")}-${values.target}.json`,
    outputDir,
  );
  await writeFile(output, `${JSON.stringify(result, null, 2)}\n`);
  console.log(
    JSON.stringify({ result, evidence: fileURLToPath(output) }, null, 2),
  );
  if (
    result.modelError ||
    result.toolErrors ||
    result.unavailable ||
    connectionCheck?.isError
  )
    process.exitCode = 1;
} finally {
  process.removeListener("SIGINT", stop);
  process.removeListener("SIGTERM", stop);
  await harness.stop();
}
