import test from "node:test";
import { execFileSync } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { packet } from "../media.mjs";

test(
  "browser packets decode in the actual ProbeViewer Swift parser",
  { skip: process.platform !== "darwin" },
  async () => {
    const dir = await mkdtemp(join(tmpdir(), "slz-native-media-"));
    try {
      await writeFile(
        join(dir, "check.swift"),
        `
import Foundation
@main struct Check {
  static func main() {
    do {
      var parser = PacketParser()
      let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
      var packets: [MediaPacket] = []
      for byte in bytes { packets += try parser.append(Data([byte])) }
      guard packets.map({ $0.header.kind }) == ["jpeg", "status", "paused"],
            packets[0].payload == Data([255,216,255,217]),
            packets[0].header.sequence == 9,
            packets[1].header.reason == "browser_screencast",
            packets[2].header.reason == "stopped" else { exit(2) }
    } catch { fputs("Decode failed: \\(error)\\n", stderr); exit(1) }
  }
}
`,
      );
      await writeFile(
        join(dir, "frames.bin"),
        Buffer.concat([
          packet(
            {
              kind: "jpeg",
              generation: 2,
              sequence: 9,
              timestamp: 123,
              target: "owned-tab",
            },
            Buffer.from([255, 216, 255, 217]),
          ),
          packet({
            kind: "status",
            generation: 2,
            reason: "browser_screencast",
          }),
          packet({ kind: "paused", generation: 3, reason: "stopped" }),
        ]),
      );
      execFileSync(
        "xcrun",
        [
          "swiftc",
          "-parse-as-library",
          fileURLToPath(
            new URL(
              "../../shared-window-probe/Shared/Protocol.swift",
              import.meta.url,
            ),
          ),
          join(dir, "check.swift"),
          "-o",
          join(dir, "check"),
        ],
        { timeout: 60000 },
      );
      execFileSync(join(dir, "check"), [join(dir, "frames.bin")], {
        timeout: 10000,
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  },
);
