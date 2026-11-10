// Read-only native connection lifecycle test. Run with the owned fixture already open.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { connectHarness } from "./harness.mjs";
import { codexRuntime, isFixturePermission } from "./runtime.mjs";

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    throw error;
  }
}
async function attach(harness) {
  const result = await harness.agent.state.tools
    .find((tool) => tool.name === "js")
    .execute(
      "read-fixture",
      {
        code: 'await cua.getApp("dev.slopzooka.codex-runtime-fixture");',
        title: "Read disposable fixture for independent connection test",
        timeout_ms: 10_000,
      },
      new AbortController().signal,
    );
  assert.equal(result.isError, false, "Native fixture attachment failed");
  const text = result.content
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
  assert(
    text.includes("Counter: 2") && text.includes("pi-direct"),
    "Expected completed fixture state missing",
  );
  return { counter2Observed: true, inputObserved: "pi-direct" };
}

const startedAt = new Date().toISOString();
const sessions = [];
const report = { startedAt, modelInvoked: false, checks: {} };
try {
  for (let i = 0; i < 2; i++) {
    const config = await codexRuntime("computer");
    const harness = await connectHarness({
      ...config,
      // No model is called: direct calls isolate the runtime lifecycle boundary.
      streamFn: () => {
        throw new Error("This check must not invoke a model");
      },
      approveElicitation: isFixturePermission,
    });
    const pid = config.transport.pid;
    assert.equal(typeof pid, "number");
    sessions.push({ harness, pid });
  }
  report.checks.clientA = await attach(sessions[0].harness);
  report.checks.clientB = await attach(sessions[1].harness);
  await sessions[0].harness.stop();
  assert.equal(alive(sessions[0].pid), false);
  assert.equal(alive(sessions[1].pid), true);
  report.checks.clientAClosedWhileBAlive = true;
  report.checks.clientBAfterAClosed = await attach(sessions[1].harness);
} finally {
  await Promise.all(sessions.map(({ harness }) => harness.stop()));
}
report.checks.ownedChildrenExited = sessions.every(({ pid }) => !alive(pid));
assert.equal(report.checks.ownedChildrenExited, true);
report.limits =
  "Read-only two-client attachment and owned-process cleanup; not concurrent input, helper crash, desktop-closed startup or native action cancellation.";
await mkdir(new URL("./build/", import.meta.url), { recursive: true });
await writeFile(
  new URL("./build/native-lifecycle.json", import.meta.url),
  JSON.stringify(report, null, 2) + "\n",
);
console.log(JSON.stringify(report, null, 2));
