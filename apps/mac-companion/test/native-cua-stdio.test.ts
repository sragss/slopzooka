import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import fs from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";

test(
  "two native REPLs initialize independently, contend only during input, and recover on completion or peer exit",
  { timeout: 15000 },
  async () => {
    const dir = await fs.mkdtemp("/tmp/slz-native-input-");
    const peer =
      'require("node:readline").createInterface({input:process.stdin}).on("line", l=>{ const m=JSON.parse(l); console.log(JSON.stringify({jsonrpc:"2.0",id:m.id,result:{content:[]}})); });';
    function start() {
      const proc = spawn(
        process.execPath,
        [
          "--import",
          "tsx",
          path.resolve(import.meta.dirname, "../src/native-cua-stdio.ts"),
          path.join(dir, "input.sqlite"),
          process.execPath,
          "-e",
          peer,
        ],
        { stdio: ["pipe", "pipe", "inherit"] },
      );
      const lines = createInterface({ input: proc.stdout })[
        Symbol.asyncIterator
      ]();
      let id = 0;
      return {
        proc,
        async call(method: string, args = {}) {
          proc.stdin.write(
            JSON.stringify({
              jsonrpc: "2.0",
              id: ++id,
              method,
              params: { name: "js", arguments: args },
            }) + "\n",
          );
          const line = await lines.next();
          assert.equal(line.done, false);
          const reply = JSON.parse(line.value!);
          assert.equal(reply.id, id);
          return reply.result;
        },
      };
    }
    const a = start(),
      b = start();
    try {
      await Promise.all([a.call("initialize"), b.call("initialize")]);
      assert.ok(!(await a.call("tools/call")).isError);
      assert.ok(!(await b.call("tools/list")).isError);
      assert.equal((await b.call("tools/call")).isError, true);
      assert.ok(
        !(
          await a.call("tools/call", {
            completion_summary: "Finished first surface",
          })
        ).isError,
      );
      assert.ok(!(await b.call("tools/call")).isError);
      assert.equal((await a.call("tools/call")).isError, true);
      const exited = once(b.proc, "exit");
      b.proc.stdin.end();
      await exited;
      assert.ok(!(await a.call("tools/call")).isError);
    } finally {
      for (const { proc } of [a, b])
        if (proc.exitCode === null && proc.signalCode === null) {
          const exited = once(proc, "exit");
          proc.stdin.end();
          await exited;
        }
      await fs.rm(dir, { recursive: true, force: true });
    }
  },
);
