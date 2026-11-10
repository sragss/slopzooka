import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-native-video-"));
try {
  const binary = path.join(temporary, "checks");
  execFileSync("xcrun", ["swiftc", "-swift-version", "5", "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
    "packages/media/VideoProtocol.swift", "packages/media/VideoFlow.swift", "packages/media/WindowVideo.swift", "packages/media/VideoSocket.swift",
    "apps/vision-client/tests/NativeVideoChecks.swift", "apps/vision-client/tests/VideoSocketChecks.swift", "-o", binary], { cwd: root, stdio: "inherit", timeout: 60000 });
  execFileSync(binary, process.argv.includes("--hardware") ? ["--hardware"] : [], { stdio: "inherit", timeout: 30000 });
} finally { await fs.rm(temporary, { recursive: true, force: true }); }
