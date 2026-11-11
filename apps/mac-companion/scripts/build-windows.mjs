import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../../../", import.meta.url));
execFileSync("xcrun", ["swiftc", "-swift-version", "5", "-strict-concurrency=complete", "-warnings-as-errors", "-O", "-target", `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macosx14.0`,
  "packages/media/VideoProtocol.swift", "packages/media/VideoFlow.swift", "packages/media/WindowVideo.swift",
  "apps/mac-companion/native/WindowHost.swift", "apps/mac-companion/native/WindowCaptureViewer.swift",
  "-o", "apps/mac-companion/native/window-host"], { cwd: root, stdio: "inherit" });
