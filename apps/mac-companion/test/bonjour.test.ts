import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { startBonjourAdvertiser } from "../src/bonjour.js";
import type { Logger } from "../src/logger.js";

const delay = () => new Promise((resolve) => setTimeout(resolve, 30));
async function until<T>(read: () => T | Promise<T>): Promise<NonNullable<T>> {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    const value = await read();
    if (value) return value as NonNullable<T>;
    await delay();
  }
  throw new Error("Bonjour condition timed out");
}
function fixture() {
  const entries: { message: string; fields?: Record<string, unknown> }[] = [];
  const write: Logger["info"] = (message, fields) =>
    entries.push({ message, fields });
  return {
    name: `slz-test-${randomUUID()}`,
    hostId: randomUUID(),
    entries,
    logger: {
      logDir: "",
      logFilePath: "",
      info: write,
      warn: write,
      error: write,
    },
  };
}
function processes() {
  return execFileSync("ps", ["-axo", "pid=,ppid=,command="], {
    encoding: "utf8",
  })
    .trim()
    .split("\n")
    .map((row) => {
      const [, pid, parent, command] = row.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/)!;
      return { pid: Number(pid), parent: Number(parent), command: command! };
    });
}
function registrar(name: string) {
  return processes().find((row) =>
    row.command.startsWith(`/usr/bin/dns-sd -R ${name} `),
  );
}
function alive(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
}

test(
  "native registration resolves through macOS and repeated stop removes its processes",
  {
    skip: process.platform !== "darwin",
    timeout: 20000,
  },
  async (t) => {
    const context = fixture();
    const service = startBonjourAdvertiser({ ...context, port: 7777 });
    t.after(() => service.stop());
    await until(() =>
      context.entries.some(
        (entry) => entry.message === "Bonjour service advertised",
      ),
    );
    const registration = await until(() => registrar(context.name));
    const owned = processes().filter(
      (row) =>
        row.pid === registration.parent || row.parent === registration.parent,
    );
    const lookup = spawn(
      "/usr/bin/dns-sd",
      ["-L", context.name, "_slopzooka._tcp", "local."],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    let output = "";
    lookup.stdout.on("data", (chunk) => {
      output += chunk;
    });
    t.after(() => {
      lookup.kill();
    });
    const hostname = execFileSync("scutil", ["--get", "LocalHostName"], {
      encoding: "utf8",
    }).trim();
    await until(() => output.includes(`hostId=${context.hostId}`));
    assert.ok(output.includes(`at ${hostname}.local.:7777`), output);
    assert.ok(output.includes("name=SlopZooka version=0.2.0"), output);
    await Promise.all([service.stop(), service.stop()]);
    await until(() => owned.every((row) => !alive(row.pid)));
    assert.equal(
      context.entries.filter(
        (entry) => entry.message === "Bonjour service stopped",
      ).length,
      1,
    );
    assert.ok(
      !context.entries.some(
        (entry) =>
          entry.message.includes("error") ||
          entry.message.includes("unexpectedly"),
      ),
    );
  },
);

test(
  "killing the companion unregisters Bonjour without leaving a registrar or pipe guard",
  {
    skip: process.platform !== "darwin",
    timeout: 20000,
  },
  async (t) => {
    const context = fixture();
    const script = `
    import { startBonjourAdvertiser } from ${JSON.stringify(new URL("../src/bonjour.ts", import.meta.url).href)};
    const log = (message) => console.log(message);
    startBonjourAdvertiser({
      name: ${JSON.stringify(context.name)}, hostId: ${JSON.stringify(context.hostId)}, port: 7777,
      logger: { info: log, warn: log, error: log }
    });
  `;
    const parent = spawn(
      process.execPath,
      ["--import", "tsx", "--input-type=module", "-e", script],
      {
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    t.after(() => {
      parent.kill("SIGKILL");
    });
    let output = "";
    parent.stdout.on("data", (chunk) => {
      output += chunk;
    });
    parent.stderr.on("data", (chunk) => {
      output += chunk;
    });
    await until(() => output.includes("Bonjour service advertised"));
    const registration = await until(() => registrar(context.name));
    const owned = processes().filter(
      (row) =>
        row.pid === registration.parent || row.parent === registration.parent,
    );
    assert.equal(
      processes().find((row) => row.pid === registration.parent)?.parent,
      parent.pid,
    );
    const exited = once(parent, "exit");
    parent.kill("SIGKILL");
    await exited;
    await until(() => owned.every((row) => !alive(row.pid)));
  },
);

test(
  "a failed native registrar is reported and stop remains safe",
  {
    skip: process.platform !== "darwin",
    timeout: 20000,
  },
  async (t) => {
    const context = fixture();
    const service = startBonjourAdvertiser({ ...context, port: 7777 });
    t.after(() => service.stop());
    await until(() =>
      context.entries.some(
        (entry) => entry.message === "Bonjour service advertised",
      ),
    );
    const registration = await until(() => registrar(context.name));
    process.kill(registration.pid, "SIGKILL");
    await until(() =>
      context.entries.some(
        (entry) => entry.message === "Bonjour service stopped unexpectedly",
      ),
    );
    await service.stop();
    await until(() => !alive(registration.parent));
  },
);
