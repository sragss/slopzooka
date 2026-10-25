import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-vision-state-"));
const binary = path.join(temporary, "checks");
const sources = [
  "LauncherState",
  "HostConnection",
  "CompanionModels",
  "TerminalNavigation",
].map((name) =>
  path.join(root, `apps/vision-client/SlopZooka/SlopZooka/${name}.swift`),
);
try {
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-swift-version",
      "5",
      "-parse-as-library",
      ...sources,
      path.join(root, "apps/vision-client/tests/LauncherStateChecks.swift"),
      "-o",
      binary,
    ],
    { stdio: "inherit", timeout: 60_000 },
  );
  execFileSync(binary, [], { stdio: "inherit", timeout: 10_000 });
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
