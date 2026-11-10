// Invoke only during the device slot. No build or install side effects.
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    device: { type: "string" },
    app: { type: "string" },
    connection: { type: "string" },
    host: { type: "string" },
  },
});
const bundles = {
  gateway: "com.slopzooka.probe.gateway",
  viewer: "com.slopzooka.probe.viewer",
};
if (!/^[a-f0-9-]{36}$/i.test(values.device ?? "") || !bundles[values.app])
  throw new Error(
    "Use --device EXACT_UUID --app gateway|viewer [--connection PRIVATE_VIEWER_JSON]",
  );
if ((values.app === "viewer") !== Boolean(values.connection))
  throw new Error(
    "Only viewer requires --connection; Gateway Probe uses normal pairing",
  );
if (values.host) {
  const host = new URL(`http://${values.host}`);
  if (
    values.app !== "gateway" ||
    !host.hostname ||
    !host.port ||
    host.username ||
    host.password ||
    host.pathname !== "/" ||
    host.search ||
    host.hash
  )
    throw new Error("--host is a gateway-only host:port address");
}
const env = { ...process.env };
for (const key of Object.keys(env))
  if (key.startsWith("DEVICECTL_CHILD_")) delete env[key];
let run;
if (values.connection) {
  const path = resolve(values.connection),
    raw = await readFile(path, "utf8"),
    c = JSON.parse(raw);
  if (
    !c.host ||
    !Number.isInteger(c.port) ||
    !c.token ||
    !/^[a-f0-9]{64}$/i.test(c.fingerprint)
  )
    throw new Error("Invalid private viewer connection");
  env.DEVICECTL_CHILD_SLZ_PROBE_CONNECTION = raw;
  env.DEVICECTL_CHILD_SLZ_PROBE_AUTO_OPEN = "all";
  run = dirname(path);
}
// Environment rather than argv keeps the bearer out of command-line logs.
execFileSync(
  "xcrun",
  [
    "devicectl",
    "device",
    "process",
    "launch",
    "--device",
    values.device,
    "--terminate-existing",
    ...(values.host
      ? ["--", bundles[values.app], "-companionHost", values.host]
      : [bundles[values.app]]),
  ],
  { env, stdio: "inherit", timeout: 60000 },
);
if (run)
  await writeFile(
    join(run, "device-launch.json"),
    JSON.stringify(
      {
        at: new Date().toISOString(),
        device: values.device,
        bundle: bundles[values.app],
        launched: true,
        physicalVisibilityConfirmed: false,
      },
      null,
      2,
    ),
  );
