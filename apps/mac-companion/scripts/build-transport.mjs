import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../../../", import.meta.url));
execFileSync("xcrun", ["swiftc", "-swift-version", "5", "-strict-concurrency=complete", "-warnings-as-errors", "-O", "-target", `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macosx13.0`,
  "packages/transport/NativeStream.swift", "apps/mac-companion/native/TransportHost.swift",
  "-o", "apps/mac-companion/native/transport-host"], { cwd: root, stdio: "inherit" });
