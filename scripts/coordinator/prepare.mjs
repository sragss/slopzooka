// Stage an isolated, repeatable headset rig. Does not launch, install, or stop apps.
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
const root = path.resolve(import.meta.dirname, "../..");
const run =
  process.env.SLZ_COORDINATOR_RIG ??
  path.join(
    os.homedir(),
    ".slopzooka/test-rigs",
    "coordinator-" + new Date().toISOString().replaceAll(":", "-"),
  );
const mac =
  process.env.SLZ_COORDINATOR_MAC ?? "/tmp/slz-coordinator/mac/SlopZooka.app";
const vp =
  process.env.SLZ_COORDINATOR_VP ??
  "/tmp/slz-coordinator/vp/Build/Products/Debug-xros/SlopZooka.app";
const config =
  process.env.SLOPZOOKA_COORDINATOR_CONFIG ??
  path.join(os.homedir(), ".slopzooka/coordinator-development/config.json");
const signing = process.env.SLOPZOOKA_SIGN_IDENTITY;
if (!signing || signing === "-")
  throw new Error(
    "Set SLOPZOOKA_SIGN_IDENTITY to a certificate-backed identity",
  );
for (const app of [mac, vp])
  execFileSync("codesign", ["--verify", "--deep", "--strict", app]);
await fs.mkdir(run, { recursive: true, mode: 0o700 });
await fs.access(path.join(run, "rig.json")).then(
  () => {
    throw new Error("Rig already exists; select a new directory");
  },
  () => {},
);
const home = path.join(run, "home"),
  workspace = path.join(run, "workspace");
await fs.mkdir(path.join(home, "workspaces"), { recursive: true, mode: 0o700 });
await fs.mkdir(workspace, { recursive: true });
const companion = path.join(run, "Slz Coordinator Companion.app");
const headset = path.join(run, "Slz Coordinator Test.app");
await fs.cp(mac, companion, { recursive: true, verbatimSymlinks: true });
await fs.cp(vp, headset, { recursive: true, verbatimSymlinks: true });
const plist = path.join(companion, "Contents/Info.plist");
execFileSync("plutil", [
  "-replace",
  "CFBundleIdentifier",
  "-string",
  "com.slopzooka.probe.coordinator.mac",
  plist,
]);
execFileSync("plutil", [
  "-replace",
  "CFBundleName",
  "-string",
  "Slz Coordinator Companion",
  plist,
]);
execFileSync("codesign", ["--force", "--sign", signing, companion]);
const fixtureName =
  process.env.SLZ_COORDINATOR_FIXTURE_NAME ?? "Slz Coordinator Fixture";
if (!/^[A-Za-z][A-Za-z0-9 -]{0,63}$/.test(fixtureName))
  throw new Error("Invalid fixture name");
const fixture = path.join(run, fixtureName + ".app");
const fixtureBundle =
  "dev.slopzooka.coordinator-fixture." +
  createHash("sha256").update(run).digest("hex").slice(0, 12);
await fs.mkdir(path.join(fixture, "Contents/MacOS"), { recursive: true });
const state = path.join(run, "fixture-state.json");
const xml = (s) => s.replaceAll("&", "&amp;").replaceAll("<", "&lt;");
await fs.writeFile(
  path.join(fixture, "Contents/Info.plist"),
  `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${fixtureBundle}</string><key>CFBundleName</key><string>${xml(fixtureName)}</string><key>SlzFixtureTitle</key><string>${xml(fixtureName)}</string><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>SlzFixtureStatePath</key><string>${xml(state)}</string></dict></plist>`,
);
execFileSync("swiftc", [
  path.join(root, "scripts/coordinator/Fixture.swift"),
  "-o",
  path.join(fixture, "Contents/MacOS/Fixture"),
]);
execFileSync("codesign", ["--force", "--sign", signing, fixture]);
const settings = JSON.parse(await fs.readFile(config, "utf8"));
settings.nativeControl = true;
const privateConfig = path.join(run, "coordinator.json");
await fs.writeFile(privateConfig, JSON.stringify(settings), { mode: 0o600 });
const now = new Date().toISOString();
await fs.writeFile(
  path.join(home, "workspaces/index.json"),
  JSON.stringify([
    {
      workspaceId: "coordinator-fixture",
      name: "Coordinator fixture",
      repo: {
        nameWithOwner: "slopzooka/coordinator-fixture",
        name: "coordinator-fixture",
        owner: { login: "slopzooka" },
      },
      profile: "codex",
      localCheckoutPath: workspace,
      worktreePath: workspace,
      branchName: "fixture",
      baseRef: "main",
      createdAt: now,
      updatedAt: now,
    },
  ]),
);
await fs.writeFile(
  path.join(workspace, "README.md"),
  `# Disposable coordinator fixture\n\nNo source edits, builds, new worktrees or network are needed. The fixture app is at ${JSON.stringify(fixture)}. Use native computer use (slopzooka-native MCP) to open that exact path. For the requested fixture test, click Increment exactly twice and enter headset-ready in Probe input. Do not edit the fixture state file. If the user requests a headset preview, use slopzooka-previews: check availability and locate the exact running app/window, then open it as Coordinator check. Report missing permission or offline state honestly. For a follow-up, make only the changes the user asks for.\n`,
);
const rig = {
  home,
  companion,
  headset,
  fixture,
  state,
  workspace,
  config: privateConfig,
  bundleId: "com.slopzooka.probe.coordinator",
  port: Number(process.env.SLZ_COORDINATOR_PORT ?? 55431),
  revision: execFileSync("git", ["rev-parse", "HEAD"], {
    cwd: root,
    encoding: "utf8",
  }).trim(),
  preparedAt: now,
};
await fs.writeFile(path.join(run, "rig.json"), JSON.stringify(rig, null, 2));
console.log(run);
