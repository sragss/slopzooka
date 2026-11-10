import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-vision-state-"));
const binary = path.join(temporary, "checks");
const suites = {
  ProbeMediaChecks: ["ProbeMediaParser"],
  LauncherStateChecks: [
    "LauncherState",
    "HostConnection",
    "CompanionModels",
    "TerminalNavigation",
    "SpeechEndpoint",
  ],
  WindowGatewayChecks: [
    "WindowGateway",
    "TerminalNotifications",
    "TerminalVoiceController",
    "ImmersiveWorkspaceState",
    "WindowPersistence",
    "LauncherState",
    "HostConnection",
    "CompanionModels",
  ],
  ImmersiveWorkspaceChecks: ["ImmersiveWorkspaceState"],
  TerminalVoiceChecks: ["TerminalVoiceController", "SpeechRecognitionSegment"],
  TerminalZoomChecks: ["TerminalZoom"],
  TerminalNotificationChecks: ["TerminalNotifications"],
};
try {
  for (const [suite, sources] of Object.entries(suites)) {
    execFileSync(
      "xcrun",
      [
        "swiftc",
        "-swift-version",
        "5",
        "-parse-as-library",
        ...sources.map((name) =>
          path.join(
            root,
            `apps/vision-client/SlopZooka/SlopZooka/${name}.swift`,
          ),
        ),
        path.join(root, `apps/vision-client/tests/${suite}.swift`),
        "-o",
        binary,
      ],
      { stdio: "inherit", timeout: 60_000 },
    );
    const args =
      suite === "WindowGatewayChecks"
        ? [
            path.join(root, "packages/protocol/fixtures/window-layout.v1.json"),
            path.join(root, "packages/protocol/fixtures/session-names.v1.json"),
          ]
        : [];
    execFileSync(binary, args, { stdio: "inherit", timeout: 10_000 });
  }
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}
