import { Agent } from "@earendil-works/pi-agent-core";
import { Type } from "@earendil-works/pi-ai";
import { McpClient, toLlmContent } from "@earendil-works/pi-mcp";

// One ephemeral Pi loop and one owned MCP connection. No window or task registry.
export async function connectHarness({
  transport,
  model,
  streamFn,
  toolNames,
  systemPrompt = "",
  maxToolCalls = 8,
  requestTimeoutMs = 60_000,
  onEvent = () => {},
  approveElicitation = () => false,
}) {
  const client = new McpClient({
    name: "slopzooka-pi-cua-probe",
    version: "0.1.0",
    capabilities: { elicitation: {} },
    requestTimeoutMs,
  });
  // Policy is supplied by the caller, never by the model. Default: no new access.
  client.setRequestHandler("elicitation/create", (params) => {
    const action = approveElicitation(params) === true ? "accept" : "cancel";
    onEvent({ type: "permission_request", decision: action });
    return { action };
  });
  let unavailable;
  let calls = 0;
  client.onClose(() => {
    unavailable ??= "MCP connection closed";
  });
  client.onError(() => {
    unavailable ??= "MCP transport error";
  });
  try {
    await client.connect(transport);
    const catalog = await client.listTools();
    const tools = toolNames.map((name) => {
      const tool = catalog.find((entry) => entry.name === name);
      if (!tool) throw new Error(`Required MCP tool missing: ${name}`);
      return {
        name,
        label: name,
        description: tool.description ?? name,
        parameters: Type.Unsafe(tool.inputSchema),
        async execute(_callId, args, signal) {
          // Also guard here: a model may have queued several calls in one response.
          if (unavailable || signal?.aborted)
            throw new Error(unavailable ?? "Stopped");
          calls++;
          try {
            const result = await client.callTool(name, args, { signal });
            const content = toLlmContent(result);
            // MCP can return both content and structuredContent; keep both model-visible.
            if (
              result.structuredContent !== undefined &&
              result.content?.length
            ) {
              content.push({
                type: "text",
                text: JSON.stringify(result.structuredContent),
              });
            }
            onEvent({
              type: "tool_result",
              name,
              isError: !!result.isError,
              contentTypes: content.map((part) => part.type),
            });
            return {
              content,
              isError: !!result.isError,
              details: result.structuredContent,
            };
          } catch (error) {
            // Timeout/disconnect cannot tell us whether an action already happened.
            // Quarantine this connection rather than retrying or dispatching queued input.
            unavailable = `MCP call failed; effects may have occurred: ${error.message}`;
            onEvent({ type: "transport_failure", name, message: unavailable });
            throw new Error(unavailable, { cause: error });
          }
        },
      };
    });
    const agent = new Agent({
      initialState: {
        model,
        systemPrompt: [
          "You are running an isolated SlopZooka tool-connection experiment.",
          "Use only the supplied tools and the user-authorized fixture. Follow the runtime guidance.",
          "Report observed results precisely. Stop on initialization/access errors; do not seek alternate control paths.",
          systemPrompt,
          client.instructions ?? "",
        ].join("\n\n"),
        tools,
      },
      streamFn,
      toolExecution: "sequential",
      async beforeToolCall() {
        if (unavailable || calls >= maxToolCalls) {
          return {
            block: true,
            terminate: true,
            reason: unavailable ?? "Probe tool-call limit reached",
          };
        }
      },
      finishTurn() {
        if (unavailable || calls >= maxToolCalls) return { action: "end" };
      },
    });
    return {
      agent,
      metadata: {
        server: client.serverInfo,
        protocolVersion: client.protocolVersion,
        toolNames,
        serverInstructionsPresent: !!client.instructions,
      },
      get unavailable() {
        return unavailable;
      },
      async stop() {
        unavailable ??= "Stopped by caller; in-flight effects cannot be undone";
        agent.clearAllQueues();
        agent.abort();
        await client.close();
        await agent.waitForIdle();
      },
    };
  } catch (error) {
    await client.close();
    throw error;
  }
}
