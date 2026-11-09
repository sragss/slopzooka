import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { createModels } from "@earendil-works/pi-ai";
import {
  fauxProvider,
  fauxAssistantMessage,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { StdioTransport } from "@earendil-works/pi-mcp";
import { createInMemoryTransportPair } from "@earendil-works/pi-mcp/testing";
import { connectHarness } from "../harness.mjs";
import { fixtureServer, card } from "../fixture.mjs";
import { subprocessEnvironment, isFixturePermission } from "../runtime.mjs";

const toolCall = (args, id) => fauxToolCall("visual_fixture", args, { id });
const toolTurn = (...calls) =>
  fauxAssistantMessage(calls, { stopReason: "toolUse" });

function modelWith(responses) {
  const faux = fauxProvider();
  const models = createModels();
  models.setProvider(faux.provider);
  faux.setResponses(responses);
  return {
    faux,
    model: faux.getModel(),
    streamFn: models.streamSimple.bind(models),
  };
}

async function memoryServer(intercept) {
  const pair = createInMemoryTransportPair();
  const received = [];
  const handle = fixtureServer((message) => pair.server.send(message));
  pair.server.onMessage((message) => {
    received.push(message);
    if (!intercept?.(message)) void handle(message);
  });
  await pair.server.start();
  return { transport: pair.client, received };
}

test("actual Pi loop receives MCP guidance, image, structured data and final action result", async () => {
  const server = await memoryServer();
  const model = modelWith([
    (context) => {
      const system = JSON.stringify(
        context.messages.filter((message) => message.role === "system"),
      );
      assert.match(system, /First observe the visual card/);
      assert.match(system, /Disposable visual transport test/);
      return toolTurn(toolCall({ action: "observe" }, "observe"));
    },
    (context) => {
      const result = context.messages.findLast(
        (message) => message.role === "toolResult",
      );
      assert.equal(result.isError, false);
      assert.deepEqual(
        result.content.find((part) => part.type === "image"),
        { type: "image", mimeType: "image/png", data: card },
      );
      assert(
        result.content.some(
          (part) => part.type === "text" && part.text === '{"observed":true}',
        ),
      );
      return toolTurn(toolCall({ action: "answer", color: "red" }, "answer"));
    },
    (context) => {
      const result = context.messages.findLast(
        (message) => message.role === "toolResult",
      );
      assert.match(result.content[0].text, /"passed":true/);
      return fauxAssistantMessage("Confirmed from fixture result.");
    },
  ]);
  const harness = await connectHarness({
    ...server,
    ...model,
    toolNames: ["visual_fixture"],
  });
  try {
    await harness.agent.prompt("Use fixture");
    assert.equal(model.faux.state.callCount, 3);
    assert.equal(harness.agent.state.errorMessage, undefined);
    assert.equal(
      server.received.filter((message) => message.method === "tools/call")
        .length,
      2,
    );
  } finally {
    await harness.stop();
  }
});

test("MCP isError remains an error in the next model observation", async () => {
  const server = await memoryServer();
  const model = modelWith([
    toolTurn(toolCall({ action: "answer", color: "blue" }, "bad-answer")),
    (context) => {
      const result = context.messages.findLast(
        (message) => message.role === "toolResult",
      );
      assert.equal(result.isError, true);
      assert.match(result.content[0].text, /"passed":false/);
      return fauxAssistantMessage("The fixture rejected my answer.");
    },
  ]);
  const harness = await connectHarness({
    ...server,
    ...model,
    toolNames: ["visual_fixture"],
  });
  try {
    await harness.agent.prompt("Use fixture");
    assert.equal(model.faux.state.callCount, 2);
    assert.equal(harness.agent.state.errorMessage, undefined);
  } finally {
    await harness.stop();
  }
});

test("lost reply quarantines connection: no retry, queued mutation or next model call", async () => {
  const server = await memoryServer(
    (message) => message.method === "tools/call",
  );
  const model = modelWith([
    toolTurn(
      toolCall({ action: "observe" }, "first"),
      toolCall({ action: "answer", color: "red" }, "queued"),
    ),
  ]);
  const harness = await connectHarness({
    ...server,
    ...model,
    toolNames: ["visual_fixture"],
    requestTimeoutMs: 40,
  });
  try {
    await harness.agent.prompt("Use fixture");
    assert.match(harness.unavailable, /effects may have occurred/);
    assert.equal(
      server.received.filter((message) => message.method === "tools/call")
        .length,
      1,
    );
    assert.equal(model.faux.state.callCount, 1);
    assert(
      server.received.some(
        (message) => message.method === "notifications/cancelled",
      ),
    );
  } finally {
    await harness.stop();
  }
});

test("Stop aborts in-flight request and prevents the second queued tool call", async () => {
  let dispatched;
  const started = new Promise((resolve) => {
    dispatched = resolve;
  });
  const server = await memoryServer((message) => {
    if (message.method !== "tools/call") return false;
    dispatched();
    return true;
  });
  const model = modelWith([
    toolTurn(
      toolCall({ action: "observe" }, "first"),
      toolCall({ action: "answer", color: "red" }, "queued"),
    ),
  ]);
  const harness = await connectHarness({
    ...server,
    ...model,
    toolNames: ["visual_fixture"],
  });
  const running = harness.agent.prompt("Use fixture");
  await started;
  await harness.stop();
  await running;
  assert.equal(
    server.received.filter((message) => message.method === "tools/call").length,
    1,
  );
  assert.equal(harness.agent.state.isStreaming, false);
  assert.equal(model.faux.state.callCount, 1);
});

test("real stdio MCP session exchanges image and reaps its owned process on Stop", async () => {
  const transport = new StdioTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL("../fixture.mjs", import.meta.url))],
    inheritEnv: false,
    env: subprocessEnvironment(),
  });
  const model = modelWith([
    toolTurn(toolCall({ action: "observe" }, "observe")),
    (context) => {
      assert(
        context.messages.at(-1).content.some((part) => part.type === "image"),
      );
      return fauxAssistantMessage("Image received over stdio.");
    },
  ]);
  const harness = await connectHarness({
    transport,
    ...model,
    toolNames: ["visual_fixture"],
  });
  const pid = transport.pid;
  try {
    await harness.agent.prompt("Observe fixture");
    assert.equal(harness.agent.state.errorMessage, undefined);
  } finally {
    await harness.stop();
  }
  assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
});

test("child environment excludes model keys and parent desktop session identity", () => {
  const env = subprocessEnvironment(
    { CUA_REPL_ENABLED_SURFACES: "browser" },
    {
      HOME: "/test-home",
      PATH: "/test-bin",
      OPENAI_API_KEY: "do-not-forward",
      CODEX_THREAD_ID: "parent",
      BROWSER_USE_ACCESS_PIPE_PATH: "/private-pipe",
      BROWSER_USE_ACCESS_EXECUTOR_ID: "parent-executor",
    },
  );
  assert.deepEqual(env, {
    HOME: "/test-home",
    PATH: "/test-bin",
    CUA_REPL_ENABLED_SURFACES: "browser",
  });
});

test("fixture permission policy rejects other apps, connectors and missing metadata", () => {
  const meta = {
    connector_id: "computer-use",
    tool_params: { app: "dev.slopzooka.codex-runtime-fixture" },
  };
  assert.equal(isFixturePermission({ _meta: meta }), true);
  assert.equal(isFixturePermission({ meta }), true);
  assert.equal(
    isFixturePermission({ _meta: { ...meta, connector_id: "browser" } }),
    false,
  );
  assert.equal(
    isFixturePermission({
      _meta: { ...meta, tool_params: { app: "com.openai.chat" } },
    }),
    false,
  );
  assert.equal(isFixturePermission({}), false);
});
