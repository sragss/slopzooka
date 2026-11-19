// Keep each worker's native REPL independent. Hold shared Mac input only from
// the first tool call until completion/reset, disconnection, or an idle timeout.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { once } from "node:events";
import type { Writable } from "node:stream";

const [lock, command, ...args] = process.argv.slice(2);
if (!lock || !command)
  throw new Error(
    "Native CUA wrapper requires a lock path and runtime command.",
  );
const db = new DatabaseSync(lock);
const child = spawn(command, args, { stdio: ["pipe", "pipe", "inherit"] });
const calls = new Map<string | number, boolean>();
let held = false;
let needsReset = false;
let idle: NodeJS.Timeout | undefined;
function release() {
  clearTimeout(idle);
  if (held) db.exec("ROLLBACK");
  held = false;
}
async function write(stream: Writable, line: string) {
  if (!stream.write(line + "\n")) await once(stream, "drain");
}
async function receive() {
  for await (const line of createInterface({ input: process.stdin })) {
    const msg = JSON.parse(line);
    if (msg.method === "tools/call" && msg.id != null) {
      const reset = msg.params?.name?.endsWith("reset") === true;
      let reason = "";
      if (needsReset && !reset) {
        reason =
          "Native input expired while idle. Reset this REPL and observe the target again.";
      } else if (!held) {
        try {
          db.exec("BEGIN IMMEDIATE");
          held = true;
        } catch (error) {
          if ((error as { errcode?: number }).errcode !== 5) throw error;
          reason =
            "Another SlopZooka worker is using Mac input. Continue other work or retry after it finishes.";
        }
      }
      if (reason) {
        await write(
          process.stdout,
          JSON.stringify({
            jsonrpc: "2.0",
            id: msg.id,
            result: {
              isError: true,
              content: [{ type: "text", text: reason }],
            },
          }),
        );
        continue;
      }
      clearTimeout(idle);
      calls.set(
        msg.id,
        reset || typeof msg.params?.arguments?.completion_summary === "string",
      );
      if (reset) needsReset = false;
    }
    await write(child.stdin, line);
  }
}
async function send() {
  for await (const line of createInterface({ input: child.stdout })) {
    if (calls.size) {
      const msg = JSON.parse(line);
      if (!msg.method && calls.has(msg.id)) {
        const finished = calls.get(msg.id);
        calls.delete(msg.id);
        if (!calls.size) {
          if (finished && !msg.error && !msg.result?.isError) release();
          else
            idle = setTimeout(() => {
              release();
              needsReset = true;
            }, 60_000).unref();
        }
      }
    }
    await write(process.stdout, line);
  }
}
process.on("exit", () => {
  child.kill();
});
process.on("SIGTERM", () => process.exit(0));
Promise.race([
  receive(),
  send(),
  once(child, "error").then(([error]) => {
    throw error;
  }),
]).then(
  () => process.exit(0),
  () => process.exit(1),
);
