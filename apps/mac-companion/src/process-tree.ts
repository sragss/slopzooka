import { execFileSync } from "node:child_process";

type ProcessRecord = { pid: number; parent: number; started: string };
function processes(): ProcessRecord[] {
  const output = execFileSync("ps", ["-axo", "pid=,ppid=,lstart="], {
    encoding: "utf8",
    timeout: 2000,
  });
  return output.split("\n").flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/);
    return match
      ? [
          {
            pid: Number(match[1]),
            parent: Number(match[2]),
            started: match[3]!,
          },
        ]
      : [];
  });
}
function signal(pid: number, name: NodeJS.Signals): void {
  try {
    process.kill(pid, name);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
}
/** Terminate only descendants of this PTY, checking start times before delayed escalation. */
export async function stopProcessTree(
  pid: number,
  stopTerminal: () => void,
): Promise<void> {
  const snapshot = processes();
  const owned = new Set([pid]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const record of snapshot)
      if (owned.has(record.parent) && !owned.has(record.pid)) {
        owned.add(record.pid);
        grew = true;
      }
  }
  const targets = snapshot.filter((p) => owned.has(p.pid));
  for (const record of targets.filter((p) => p.pid !== pid).reverse())
    signal(record.pid, "SIGTERM");
  stopTerminal();
  await new Promise((resolve) => setTimeout(resolve, 500));
  const current = new Map(processes().map((p) => [p.pid, p.started]));
  for (const record of targets)
    if (current.get(record.pid) === record.started)
      signal(record.pid, "SIGKILL");
}
