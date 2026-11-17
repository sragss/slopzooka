import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

const home = process.env.CODEX_HOME;
const record = (value) => fs.appendFileSync(path.join(home, "calls.jsonl"), JSON.stringify(value) + "\n");
const args = process.argv.slice(2);
record({ args, cwd: process.cwd(), pid: process.pid });
if (args[0] === "resume") {
  console.log("RESUMED_FIXTURE");
  process.stdin.on("data", () => process.exit(0));
} else if (args[0] === "app-server") {
  const mode = fs.existsSync(path.join(home, "mode")) ? fs.readFileSync(path.join(home, "mode"), "utf8") : "normal";
  if (mode === "exit") process.exit(1);
  const threads = Array.from({ length: 30 }, (_, index) => ({
    id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
    name: index === 0 ? null : `Private thread ${index}`,
    preview: "Fallback title\nprivate conversation",
    cwd: path.join(home, index === 2 ? "missing" : "project"),
    updatedAt: 2000 - index,
    ephemeral: false,
    turns: [],
  }));
  const lines = readline.createInterface({ input: process.stdin });
  lines.on("line", (line) => {
    const message = JSON.parse(line);
    record({ method: message.method, params: message.params });
    if (mode === "hang" || message.id === undefined) return;
    if (mode === "oversize") { process.stdout.write("x".repeat(5 * 1024 * 1024)); return; }
    if (mode === "malformed") { console.log(JSON.stringify({ id: message.id, result: { data: null } })); return; }
    let result;
    if (message.method === "initialize") result = {};
    if (message.method === "thread/list") result = { data: threads, nextCursor: "do-not-follow" };
    if (message.method === "thread/read") {
      const thread = threads.find((thread) => thread.id === message.params.threadId);
      if (!thread) { console.log(JSON.stringify({ id: message.id, error: { code: -32600, message: "private error" } })); return; }
      result = { thread };
    }
    console.log(JSON.stringify({ id: message.id, result }));
  });
  lines.on("close", () => process.exit(0));
}
