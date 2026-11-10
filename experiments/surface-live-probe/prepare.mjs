// Build/preflight only. Explicit --install is reserved for the user's live slot.
import { execFileSync } from "node:child_process";
import { mkdir, writeFile, open } from "node:fs/promises";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
const { values } = parseArgs({
  options: {
    team: { type: "string" },
    device: { type: "string" },
    install: { type: "boolean" },
  },
});
if (!values.team) throw new Error("Pass --team EXISTING_DEVELOPMENT_TEAM");
if (values.install && !values.device)
  throw new Error("--install requires the exact --device UUID");
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const build = join(root, "experiments/surface-live-probe/build/prepared");
await mkdir(build, { recursive: true });
async function run(name, args) {
  const log = await open(join(build, name + ".log"), "w");
  try {
    execFileSync("xcodebuild", args, {
      cwd: root,
      stdio: ["ignore", log.fd, log.fd],
      timeout: 600000,
    });
    console.log(name + ": passed");
  } finally {
    await log.close();
  }
}
await run("gateway", [
  "-project",
  "apps/vision-client/SlopZooka/SlopZooka.xcodeproj",
  "-scheme",
  "SlopZooka",
  "-configuration",
  "Debug",
  "-destination",
  "generic/platform=visionOS",
  "-derivedDataPath",
  join(build, "gateway"),
  `DEVELOPMENT_TEAM=${values.team}`,
  "PRODUCT_BUNDLE_IDENTIFIER=com.slopzooka.probe.gateway",
  "INFOPLIST_KEY_CFBundleDisplayName=SlopZooka Gateway Probe",
  "-allowProvisioningUpdates",
  "build",
]);
await run("viewer", [
  "-project",
  "experiments/shared-window-probe/build/SharedWindowProbe.xcodeproj",
  "-scheme",
  "ProbeViewer",
  "-configuration",
  "Debug",
  "-destination",
  "generic/platform=visionOS",
  "-derivedDataPath",
  join(build, "viewer"),
  `DEVELOPMENT_TEAM=${values.team}`,
  "-allowProvisioningUpdates",
  "build",
]);
const artifacts = {
  gateway: join(build, "gateway/Build/Products/Debug-xros/SlopZooka.app"),
  viewer: join(build, "viewer/Build/Products/Debug-xros/ProbeViewer.app"),
  gatewayBundle: "com.slopzooka.probe.gateway",
  viewerBundle: "com.slopzooka.probe.viewer",
  at: new Date().toISOString(),
  installed: false,
};
if (values.install) {
  for (const app of [artifacts.gateway, artifacts.viewer])
    execFileSync(
      "xcrun",
      ["devicectl", "device", "install", "app", "--device", values.device, app],
      { stdio: "inherit", timeout: 120000 },
    );
  artifacts.installed = true;
}
await writeFile(
  join(build, "artifacts.json"),
  JSON.stringify(artifacts, null, 2),
);
console.log(JSON.stringify(artifacts));
