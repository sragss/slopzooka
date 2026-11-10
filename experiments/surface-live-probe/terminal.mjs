import { spawn, execFileSync } from "node:child_process";
import { readFile, writeFile, mkdtemp, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
const { values } = parseArgs({
  options: {
    codex: { type: "string" },
    config: { type: "string" },
    "prompt-file": { type: "string" },
  },
});
if (!values.codex || !values.config || !values["prompt-file"])
  throw new Error(
    "Pass --codex EXPLICIT_EXECUTABLE --config PRIVATE_AGENT_CONFIG --prompt-file FILE",
  );
const config = resolve(values.config),
  cwd = await mkdtemp(join(tmpdir(), "slz-live-cli-")),
  started = Date.now();
const env = Object.fromEntries(
  ["HOME", "PATH", "TMPDIR", "LANG", "USER", "LOGNAME"]
    .filter((k) => process.env[k])
    .map((k) => [k, process.env[k]]),
);
const args = [
  "exec",
  "--ignore-user-config",
  "--ephemeral",
  "--json",
  "--sandbox",
  "read-only",
  "--skip-git-repo-check",
  "--cd",
  cwd,
  "-c",
  "features.shell_tool=false",
  "-c",
  "features.apps=false",
  "-c",
  "features.plugins=false",
  "-c",
  'web_search="disabled"',
  "-c",
  'approval_policy="never"',
  "-c",
  `mcp_servers.surface_probe.command=${JSON.stringify(process.execPath)}`,
  "-c",
  `mcp_servers.surface_probe.args=${JSON.stringify([fileURLToPath(new URL("./mcp.mjs", import.meta.url)), config])}`,
  "-c",
  'mcp_servers.surface_probe.default_tools_approval_mode="approve"',
  "-c",
  "mcp_servers.surface_probe.required=true",
  "-",
];
const child = spawn(values.codex, args, {
  cwd,
  env,
  stdio: ["pipe", "pipe", "pipe"],
});
let output = "",
  errors = "";
child.stdout.on("data", (data) => {
  output += data;
});
child.stderr.on("data", (data) => {
  errors = (errors + data).slice(-20000);
});
for (const signal of ["SIGINT", "SIGTERM"])
  process.once(signal, () => child.kill(signal));
try {
  const done = new Promise((resolve, reject) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
    child.once("error", reject);
  });
  child.stdin.end(await readFile(values["prompt-file"], "utf8"));
  const end = await done;
  const rows = output
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const items = rows
    .filter((row) => row.type === "item.completed")
    .map((row) => row.item);
  const result = {
    ...end,
    version: execFileSync(values.codex, ["--version"], {
      encoding: "utf8",
    }).trim(),
    elapsedMs: Date.now() - started,
    calls: items.filter((i) => i.type === "mcp_tool_call").length,
    itemTypes: [...new Set(items.map((i) => i.type))],
    onlyFixtureTools: items.every(
      (i) =>
        i.type === "agent_message" ||
        (i.type === "mcp_tool_call" && i.server === "surface_probe"),
    ),
  };
  const prefix = join(dirname(config), `terminal-${started}`);
  await writeFile(prefix + ".jsonl", output, { mode: 0o600 });
  await writeFile(prefix + ".stderr", errors, { mode: 0o600 });
  await writeFile(prefix + ".json", JSON.stringify(result, null, 2));
  console.log(JSON.stringify({ resultFile: prefix + ".json", ...result }));
  if (end.code !== 0 || !result.onlyFixtureTools || !result.calls)
    process.exitCode = 1;
} finally {
  if (child.exitCode === null) child.kill("SIGTERM");
  await rm(cwd, { recursive: true, force: true });
}
