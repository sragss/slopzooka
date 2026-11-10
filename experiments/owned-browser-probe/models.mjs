import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { parseEnv } from "node:util";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createModels } from "@earendil-works/pi-ai";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { StdioTransport } from "@earendil-works/pi-mcp";
import { connectHarness } from "../pi-cua-probe/harness.mjs";
import { tools } from "./mcp.mjs";

export async function runModels({
  socketPath,
  origin,
  run,
  fixtureEvents,
  keyFile,
}) {
  if (!keyFile)
    throw new Error(
      "--models requires --key-file PATH; no secrets in arguments",
    );
  const credentials = parseEnv(await readFile(keyFile, "utf8"));
  const models = createModels();
  models.setProvider(openaiProvider());
  models.setProvider(anthropicProvider());
  const env = Object.fromEntries(
    ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"]
      .filter((key) => process.env[key])
      .map((key) => [key, process.env[key]]),
  );
  // These are two separate live Pi agents, independent MCP processes and tabs.
  const outcomes = await Promise.allSettled(
    [
      ["openai", "gpt-6.1-sol", "OPENAI_API_KEY", "gpt"],
      ["anthropic", "claude-opus-5-5", "ANTHROPIC_API_KEY", "opus"],
    ].map(async ([provider, modelId, keyName, label]) => {
      const apiKey = credentials[keyName];
      if (!apiKey) throw new Error(`Missing ${keyName} in selected file`);
      const model = models.getModel(provider, modelId);
      if (!model) throw new Error(`Pinned Pi catalog has no ${modelId}`);
      const events = [];
      const started = performance.now();
      const harness = await connectHarness({
        transport: new StdioTransport({
          command: process.execPath,
          args: [
            fileURLToPath(new URL("./mcp.mjs", import.meta.url)),
            socketPath,
          ],
          env,
          inheritEnv: false,
        }),
        model,
        toolNames: tools.map((tool) => tool.name),
        maxToolCalls: 14,
        streamFn: (m, context, options) =>
          models.streamSimple(m, context, {
            ...options,
            apiKey,
            reasoning: "low",
            maxTokens: 2048,
            maxRetries: 0,
          }),
        onEvent: (event) =>
          events.push({
            elapsedMs: Math.round(performance.now() - started),
            ...event,
          }),
      });
      const timeout = setTimeout(() => void harness.stop(), 120_000);
      try {
        await harness.agent.prompt(
          `Use only these browser tools and the disposable page ${origin}/${label}. Open it in a background tab. Observe, fill Workspace label with pi-${label}, save the label, click Increment exactly twice, and open Settings. Verify Counter: 2, the label, and Settings page from a fresh observation, then take and inspect a screenshot. Leave the tab open. Stop on initialization or access errors. Do not retry any uncertain input. Report only what you actually verified. Complete within 14 tool calls.`,
        );
        const messages = harness.agent.state.messages;
        const images = messages
          .filter((message) => message.role === "toolResult")
          .flatMap((message) =>
            message.content.filter((part) => part.type === "image"),
          );
        const last = messages.findLast(
          (message) => message.role === "assistant",
        );
        const rows = fixtureEvents.filter(
          (event) => event.fixture === `/${label}`,
        );
        const result = {
          provider,
          model: modelId,
          elapsedMs: Math.round(performance.now() - started),
          final: last?.content
            .filter((part) => part.type === "text")
            .map((part) => part.text)
            .join("\n"),
          stopReason: last?.stopReason,
          modelError: last?.errorMessage,
          toolErrors: messages.filter(
            (message) => message.role === "toolResult" && message.isError,
          ).length,
          images: images.length,
          events,
          requests: messages
            .filter((message) => message.role === "assistant")
            .map((message) => ({
              stopReason: message.stopReason,
              usage: message.usage,
            })),
          fixtureEvents: rows,
        };
        await writeFile(
          join(run, `${label}-model.json`),
          JSON.stringify(result, null, 2),
        );
        if (images.length)
          await writeFile(
            join(run, `${label}-model.jpg`),
            Buffer.from(images.at(-1).data, "base64"),
          );
        assert.deepEqual(
          rows.map((event) => event.action),
          ["save", "increment", "increment", "settings"],
        );
        assert(rows.every((event) => event.label === `pi-${label}`));
        assert.equal(rows.at(-1).count, 2);
        assert.equal(result.toolErrors, 0);
        assert(images.length >= 1, "Model must receive the actual screenshot");
        assert.equal(last?.stopReason, "stop");
        return {
          provider,
          model: modelId,
          elapsedMs: result.elapsedMs,
          images: images.length,
          fixtureEvents: rows.length,
          toolCalls: events.filter((event) => event.type === "tool_result")
            .length,
          toolErrors: result.toolErrors,
        };
      } finally {
        clearTimeout(timeout);
        await harness.stop();
      }
    }),
  );
  const failures = outcomes.filter((outcome) => outcome.status === "rejected");
  if (failures.length)
    throw new AggregateError(
      failures.map((outcome) => outcome.reason),
      "Live model fixture failed; see per-model artifacts",
    );
  return outcomes.map((outcome) => outcome.value);
}
