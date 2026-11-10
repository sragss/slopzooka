import { execFileSync } from "node:child_process";

function candidates(udid, probeRoot) {
  return execFileSync("ps", ["-axo", "pid=,lstart=,command="], {
    encoding: "utf8",
  })
    .split("\n")
    .flatMap((line) => {
      const m = /^\s*(\d+)\s+(.{24})\s+(.+)$/.exec(line);
      if (!m) return [];
      const command = m[3];
      const wda =
        command.includes("WebDriverAgentRunner") &&
        command.includes(udid) &&
        (command.includes(probeRoot) ||
          command.includes(`/CoreSimulator/Devices/${udid}/`));
      const diagnostic =
        command.includes("simctl diagnose") &&
        command.includes(`--udid=${udid}`) &&
        command.includes(probeRoot);
      return wda || diagnostic
        ? [{ pid: Number(m[1]), started: m[2], command }]
        : [];
    });
}
export function requireIdleDeviceDriver(udid, probeRoot) {
  const running = candidates(udid, probeRoot);
  if (running.length)
    throw new Error(
      `Existing probe device driver processes (${running.map((p) => p.pid)}); finish that owned run before starting another`,
    );
}
export async function stopOwnedDeviceDriver(udid, probeRoot) {
  // Startup required this dedicated device's driver set to be empty. Include
  // vendor children reparented to launchd, which process-group cleanup misses.
  const signaled = [];
  for (let attempt = 0; attempt < 3; attempt++) {
    const owned = candidates(udid, probeRoot);
    for (const p of owned) {
      try {
        process.kill(p.pid, "SIGTERM");
        signaled.push(p);
      } catch {}
    }
    await new Promise((r) => setTimeout(r, 500));
    const current = new Map(candidates(udid, probeRoot).map((p) => [p.pid, p]));
    for (const p of owned)
      if (
        current.get(p.pid)?.started === p.started &&
        current.get(p.pid)?.command === p.command
      ) {
        try {
          process.kill(p.pid, "SIGKILL");
        } catch {}
      }
  }
  return { signaled, remaining: candidates(udid, probeRoot) };
}
