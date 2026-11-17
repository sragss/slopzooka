import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { swiftSources } from "./swift-sources.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-voice-demo-"));
const binary = path.join(temporary, "checks");
try {
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-swift-version",
      "5",
      "-strict-concurrency=complete",
      "-warnings-as-errors",
      "-parse-as-library",
      ...(await swiftSources(path.join(root, "apps/shared"))),
      ...["TerminalVoiceController", "SpeechRecognitionSegment"].map((name) =>
        path.join(root, `apps/vision-client/SlopZooka/SlopZooka/${name}.swift`),
      ),
      path.join(root, "apps/vision-client/tests/TerminalVoiceChecks.swift"),
      "-o",
      binary,
    ],
    { stdio: "inherit", timeout: 60_000 },
  );
  execFileSync(binary, { stdio: "inherit", timeout: 15_000 });
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
