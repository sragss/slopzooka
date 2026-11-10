import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = await fs.readFile(path.join(root, ".swiftlint.yml"), "utf8");
const version = config.match(/^swiftlint_version: (\d+\.\d+\.\d+)$/m)?.[1];
if (!version) throw new Error("Missing SwiftLint version in .swiftlint.yml");
if (process.platform !== "darwin")
  throw new Error("SwiftLint setup requires macOS");

// SHA-256 of the official portable_swiftlint.zip release; update with the version.
const checksum =
  "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0";
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-swiftlint-"));
try {
  const archive = path.join(temporary, "swiftlint.zip");
  execFileSync(
    "curl",
    [
      "--fail",
      "--location",
      "--silent",
      "--show-error",
      "--retry",
      "3",
      `https://github.com/realm/SwiftLint/releases/download/${version}/portable_swiftlint.zip`,
      "--output",
      archive,
    ],
    { stdio: "inherit" },
  );
  const actual = createHash("sha256")
    .update(await fs.readFile(archive))
    .digest("hex");
  if (actual !== checksum)
    throw new Error("SwiftLint archive checksum mismatch");
  const destination = path.join(root, ".build", "swiftlint");
  await fs.mkdir(destination, { recursive: true });
  execFileSync("unzip", ["-qo", archive, "-d", destination], {
    stdio: "inherit",
  });
  execFileSync(path.join(destination, "swiftlint"), ["version"], {
    stdio: "inherit",
  });
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
