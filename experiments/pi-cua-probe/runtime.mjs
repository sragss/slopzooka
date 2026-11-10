import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { StdioTransport } from "@earendil-works/pi-mcp";

export function isFixturePermission(params) {
  const meta = params?._meta ?? params?.meta;
  return (
    meta?.connector_id === "computer-use" &&
    meta?.tool_params?.app === "dev.slopzooka.codex-runtime-fixture"
  );
}

export function subprocessEnvironment(manifestEnv = {}, parent = process.env) {
  // Model credentials and desktop session/turn/pipe identity must not leak in.
  const env = {};
  for (const key of ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"]) {
    if (parent[key] !== undefined) env[key] = parent[key];
  }
  return { ...env, ...manifestEnv };
}

export async function codexRuntime(surface) {
  if (!["browser", "computer"].includes(surface))
    throw new Error("Use browser or computer");
  const plist = await readFile(
    "/Applications/ChatGPT.app/Contents/Info.plist",
    "utf8",
  );
  const version = plist.match(
    /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/,
  )?.[1];
  if (!version) throw new Error("Could not read installed ChatGPT version");
  const manifestPath = join(
    homedir(),
    ".codex/plugins/cache/openai-bundled/unified-computer-use",
    version,
    ".mcp.json",
  );
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const config = manifest.mcpServers?.cua_repl;
  if (!config?.command)
    throw new Error("Installed manifest has no cua_repl server");
  // Preserve the genuine packaged launcher/preloader. Do not fabricate access-host context.
  const transport = new StdioTransport({
    command: config.command,
    args: config.args,
    env: subprocessEnvironment({
      ...config.env,
      CUA_REPL_ENABLED_SURFACES: surface,
    }),
    inheritEnv: false,
    stderr: "pipe",
    maxMessageBytes: 32 * 1024 * 1024,
  });
  return {
    transport,
    toolNames: ["js", "js_reset"],
    metadata: {
      version,
      surface,
      manifestPath,
      suppliedDesktopIdentity: false,
    },
  };
}
