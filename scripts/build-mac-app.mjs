import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(root);
if (process.platform !== "darwin")
  throw new Error("Build the companion app on macOS with Xcode installed.");
if (Number(process.versions.node.split(".")[0]) < 22)
  throw new Error("Node.js 22+ is required.");
const run = (command, args) =>
  execFileSync(command, args, { stdio: "inherit" });
const destination = path.join(root, "build/mac-app");
function requireStopped() {
  const bundle = path.join(destination, "SlopZooka.app");
  const processes = execFileSync("ps", ["-axo", "command="], {
    encoding: "utf8",
  }).split("\n");
  if (
    processes.some(
      (line) =>
        line.trim() === `${bundle}/Contents/MacOS/SlopZooka` ||
        line.trim().startsWith(`${bundle}/Contents/Resources/runtime/node `),
    )
  ) {
    throw new Error(
      "Quit the app running from build/mac-app before rebuilding it. Active sessions will not be interrupted by this build.",
    );
  }
}
requireStopped();
await fs.mkdir(path.dirname(destination), { recursive: true });
const build = await fs.mkdtemp(path.join(root, "build/mac-app-staging-"));
const app = path.join(build, "SlopZooka.app");
const resources = path.join(app, "Contents/Resources");
const source = path.join(root, "apps/mac-menu");
try {
  await fs.mkdir(path.join(app, "Contents/MacOS"), { recursive: true });
  await fs.mkdir(path.join(resources, "runtime"), { recursive: true });
  run("pnpm", ["build:harness"]);
  run("pnpm", [
    "--filter",
    "@slz/mac-companion",
    "deploy",
    "--prod",
    "--legacy",
    path.join(resources, "host"),
  ]);
  // Legacy deploy leaves a workspace self-link pointing back to the checkout.
  await fs.rm(
    path.join(
      resources,
      "host/node_modules/.pnpm/node_modules/@slz/mac-companion",
    ),
    { force: true },
  );
  run("pnpm", [
    "--filter",
    "@slz/mac-companion",
    "exec",
    "esbuild",
    "src/server.ts",
    "--bundle",
    "--platform=node",
    "--format=esm",
    "--packages=external",
    `--outfile=${resources}/host/src/server.mjs`,
  ]);
  await fs.copyFile(process.execPath, path.join(resources, "runtime/node"));
  await fs.chmod(path.join(resources, "runtime/node"), 0o755);
  // node-pty ships its helper without an executable bit in some package versions.
  async function fixHelpers(directory) {
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) await fixHelpers(file);
      else if (entry.name === "spawn-helper") await fs.chmod(file, 0o755);
    }
  }
  await fixHelpers(path.join(resources, "host/node_modules"));
  await fs.copyFile(
    path.join(source, "Info.plist"),
    path.join(app, "Contents/Info.plist"),
  );
  const sources = (await fs.readdir(path.join(source, "Sources")))
    .filter((name) => name.endsWith(".swift"))
    .map((name) => path.join(source, "Sources", name));
  const target = `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macosx13.0`;
  run("xcrun", [
    "swiftc",
    "-swift-version",
    "5",
    "-O",
    "-target",
    target,
    ...sources,
    "-o",
    path.join(app, "Contents/MacOS/SlopZooka"),
  ]);
  run("xcrun", [
    "swiftc",
    path.join(source, "Sources/CompanionIcon.swift"),
    path.join(source, "render-icon.swift"),
    "-o",
    path.join(build, "render-icon"),
  ]);
  run(path.join(build, "render-icon"), [path.join(build, "AppIcon.iconset")]);
  run("iconutil", [
    "-c",
    "icns",
    path.join(build, "AppIcon.iconset"),
    "-o",
    path.join(resources, "AppIcon.icns"),
  ]);
  run("codesign", ["--force", "--deep", "--sign", "-", app]);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  // Publish only a complete, signed bundle; failures preserve the previous build.
  requireStopped();
  const previous = `${build}.previous`;
  let hadPrevious = false;
  try {
    await fs.rename(destination, previous);
    hadPrevious = true;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  try {
    await fs.rename(build, destination);
  } catch (error) {
    if (hadPrevious) await fs.rename(previous, destination);
    throw error;
  }
  if (hadPrevious) await fs.rm(previous, { recursive: true, force: true });
  console.log(
    `Built ${path.join(destination, "SlopZooka.app")}\nMove it to Applications, then open it. No Node/pnpm installation is needed to run the app.`,
  );
} finally {
  await fs.rm(build, { recursive: true, force: true });
}
