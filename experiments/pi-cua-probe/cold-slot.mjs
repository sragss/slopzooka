// Disruptive test wrapper: run only in a user-approved quiet desktop slot.
import { execFileSync, spawn } from "node:child_process";
import { mkdir, mkdtemp, writeFile, appendFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (!process.argv.includes("--approved-slot"))
  throw new Error("An explicit user-approved quiet slot is required");
const base = dirname(fileURLToPath(import.meta.url));
await mkdir(join(base, "build"), { recursive: true });
const run = await mkdtemp(join(base, "build", "cold-slot-"));
const desktop = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT";
const helper =
  "/Users/samragsdale/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService";
function processes() {
  return execFileSync("/bin/ps", ["-axo", "pid=,comm="], { encoding: "utf8" })
    .split("\n")
    .map((line) => line.trim().match(/^(\d+) (.+)$/))
    .filter(Boolean)
    .map((match) => ({ pid: Number(match[1]), command: match[2] }));
}
async function until(fn, description) {
  for (let i = 0; i < 200; i++) {
    if (fn()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out: ${description}`);
}
const before = processes().filter((entry) =>
  [desktop, helper].includes(entry.command),
);
const report = {
  startedAt: new Date().toISOString(),
  userApprovedSlot: true,
  before,
};
let writes = Promise.resolve();
try {
  if (before.some((entry) => entry.command === desktop)) {
    execFileSync(
      "/usr/bin/osascript",
      ["-e", 'tell application id "com.openai.codex" to quit'],
      { timeout: 20000 },
    );
    await until(
      () => !processes().some((entry) => entry.command === desktop),
      "normal desktop quit",
    );
  }
  for (const entry of processes().filter((entry) => entry.command === helper))
    process.kill(entry.pid, "SIGTERM");
  await until(
    () =>
      !processes().some((entry) => [desktop, helper].includes(entry.command)),
    "desktop and helper absent",
  );
  report.absentBeforeClientStart = true;
  const child = spawn(
    process.execPath,
    [join(base, "qualify-native.mjs"), "--cold", "--helper-failure"],
    {
      cwd: base,
      env: Object.fromEntries(
        ["PATH", "HOME", "TMPDIR", "LANG", "USER", "LOGNAME"]
          .filter((key) => process.env[key])
          .map((key) => [key, process.env[key]]),
      ),
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  child.stdout.on("data", (data) => {
    writes = writes.then(() =>
      appendFile(join(run, "native-stdout.jsonl"), data),
    );
  });
  child.stderr.on("data", (data) => {
    writes = writes.then(() =>
      appendFile(join(run, "native-stderr.txt"), data),
    );
  });
  // Restore the desktop even if a provider call unexpectedly hangs.
  const deadline = setTimeout(() => child.kill("SIGINT"), 90000);
  report.nativeExit = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  clearTimeout(deadline);
  report.afterNativeBeforeDesktopRestore = processes().filter((entry) =>
    [desktop, helper].includes(entry.command),
  );
} catch (error) {
  report.error = error.message;
} finally {
  if (before.some((entry) => entry.command === desktop)) {
    try {
      execFileSync("/usr/bin/open", ["-a", "/Applications/ChatGPT.app"]);
      await until(
        () => processes().some((entry) => entry.command === desktop),
        "desktop restoration",
      );
      report.desktopRestored = true;
    } catch (error) {
      report.restoreError = error.message;
    }
  }
  await writes;
  await writeFile(join(run, "result.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ run, ...report }));
  if (report.error || report.nativeExit?.code !== 0 || report.restoreError)
    process.exitCode = 1;
}
