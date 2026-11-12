import { McpServer } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import * as z from "zod/v4";
import {
  PreviewControl,
  previewName,
  readPreviewConfig,
} from "./preview-control.js";
import { ServiceError } from "./errors.js";

try {
  const file = process.argv[2];
  if (!file) throw new Error("Configuration file required");
  const control = new PreviewControl(await readPreviewConfig(file));
  const run = async (operation: () => Promise<unknown>) => {
    try {
      const result = await operation();
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result) }],
      };
    } catch (error) {
      return {
        isError: true,
        content: [
          {
            type: "text" as const,
            text:
              error instanceof ServiceError
                ? error.message
                : "Preview request failed. Check the companion connection and private configuration, then retry.",
          },
        ],
      };
    }
  };
  serveStdio(() => {
    const server = new McpServer({
      name: "slopzooka-previews",
      version: "0.1.0",
    });
    server.registerTool(
      "preview_list",
      {
        description:
          "List Mac windows and desired native previews for the configured headset. Use returned source IDs. The companion handles stream sizing. Use your existing computer-use tools to interact with source apps.",
        inputSchema: z.object({}),
        annotations: { readOnlyHint: true },
      },
      () => run(() => control.list()),
    );
    server.registerTool(
      "preview_open",
      {
        description:
          "Request a native preview on the configured headset, reusing an existing preview of that source. Does not launch apps or prove the user can see it. List sources first.",
        inputSchema: z.object({
          source_id: z.string().min(1).max(512),
          name: previewName.optional(),
        }),
      },
      ({ source_id, name }) => run(() => control.open(source_id, name)),
    );
    server.registerTool(
      "preview_rename",
      {
        description:
          "Name an open native preview without restarting its stream or changing its scene identity.",
        inputSchema: z.object({
          preview_id: z.string().min(1).max(512),
          name: previewName,
        }),
      },
      ({ preview_id, name }) => run(() => control.rename(preview_id, name)),
    );
    server.registerTool(
      "preview_close",
      {
        description:
          "Request closure of a native preview. Leaves the Mac source app and terminal processes running. Acknowledgement is desired state, not observed headset visibility.",
        inputSchema: z.object({ preview_id: z.string().min(1).max(512) }),
      },
      ({ preview_id }) => run(() => control.close(preview_id)),
    );
    return server;
  });
} catch {
  // stdout is exclusively MCP. Do not print configuration or credential-bearing exceptions.
  process.stderr.write(
    "SlopZooka preview MCP could not start. Supply a valid owner-only configuration file for a local companion and explicit headset client.\n",
  );
  process.exitCode = 1;
}
