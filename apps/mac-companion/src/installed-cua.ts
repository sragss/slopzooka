import fs from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as z from "zod/v4";
import { ServiceError } from "./errors.js";

/** Experimental opt-in: use the user's installed native runtime; never copy vendor binaries
 * or borrow a desktop task's browser/session authority. Live MCP guidance stays with it. */
export async function installedNativeCua(home: string): Promise<string[]> {
  try {
    const { stdout } = await promisify(execFile)("/usr/bin/plutil", [
      "-extract",
      "CFBundleShortVersionString",
      "raw",
      "-o",
      "-",
      "/Applications/ChatGPT.app/Contents/Info.plist",
    ]);
    const version = stdout.trim();
    if (!/^[a-zA-Z0-9._-]+$/.test(version))
      throw new Error("Invalid installed version");
    const file = path.join(
      home,
      ".codex/plugins/cache/openai-bundled/unified-computer-use",
      version,
      ".mcp.json",
    );
    const manifest = z
      .object({
        mcpServers: z.object({
          cua_repl: z.object({
            command: z.string(),
            args: z.array(z.string()),
            env: z.record(z.string(), z.string()),
          }),
        }),
      })
      .parse(JSON.parse(await fs.readFile(file, "utf8")));
    const entry = manifest.mcpServers.cua_repl;
    const env = { ...entry.env, CUA_REPL_ENABLED_SURFACES: "computer" };
    if (Object.keys(env).some((key) => key.startsWith("BROWSER_USE_ACCESS_")))
      throw new Error("Manifest unexpectedly contains desktop-task authority");
    const inline = `{ ${Object.entries(env)
      .map(
        ([key, value]) => `${JSON.stringify(key)} = ${JSON.stringify(value)}`,
      )
      .join(", ")} }`;
    return [
      "-c",
      "mcp_servers.cua_repl.enabled=false",
      "-c",
      'mcp_servers.cua_repl.command="/usr/bin/false"',
      "-c",
      "mcp_servers.node_repl.enabled=false",
      "-c",
      'mcp_servers.node_repl.command="/usr/bin/false"',
      "-c",
      `mcp_servers.slopzooka-native.command=${JSON.stringify(entry.command)}`,
      "-c",
      `mcp_servers.slopzooka-native.args=${JSON.stringify(entry.args)}`,
      "-c",
      `mcp_servers.slopzooka-native.env=${inline}`,
    ];
  } catch {
    throw new ServiceError(
      "The installed native CUA runtime is unavailable or changed. Disable the experimental native-control option or repair the installation.",
      503,
    );
  }
}
