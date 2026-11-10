import { swiftSources } from "./swift-sources.mjs";
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sharedSources = await swiftSources(path.join(root, "apps/shared"));
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "slz-vision-state-"));
const binary = path.join(temporary, "checks");
const companionSources = [
  "CompanionClient",
  "CompanionTransport",
  "CompanionModels",
  "WindowPersistence",
];
const suites = {
  DiagnosticsChecks: [...companionSources, "BugReportState"],
  CompanionClientChecks: companionSources,
  LauncherStateChecks: [
    ...companionSources,
    "LauncherState",
    "TerminalNavigation",
    "SpeechEndpoint",
  ],
  WindowGatewayChecks: [
    ...companionSources,
    "WindowGateway",
    "TerminalNotifications",
    "TerminalVoiceController",
    "ImmersiveWorkspaceState",
    "LauncherState",
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
        ...(sources.includes("CompanionTransport") ? [path.join(root, "packages/transport/NativeStream.swift")] : []),
        ...sharedSources,
        ...sources.map((name) =>
          path.join(
            root,
            `apps/vision-client/SlopZooka/SlopZooka/${name}.swift`,
          ),
        ),
        ...(sources.includes("CompanionClient")
          ? [
              path.join(
                root,
                "apps/vision-client/tests/CompanionTestTransport.swift",
              ),
            ]
          : []),
        path.join(root, `apps/vision-client/tests/${suite}.swift`),
        "-o",
        binary,
      ],
      { stdio: "inherit", timeout: 60_000 },
    );
    const args =
      suite === "DiagnosticsChecks"
        ? [
            path.join(root, "packages/protocol/fixtures/diagnostics.v1.json"),
            temporary,
          ]
        : suite === "WindowGatewayChecks"
          ? [
              path.join(
                root,
                "packages/protocol/fixtures/window-layout.v1.json",
              ),
              path.join(
                root,
                "packages/protocol/fixtures/session-names.v1.json",
              ),
              path.join(root, "packages/protocol/fixtures/native-window.v1.json"),
            ]
          : suite === "CompanionClientChecks"
            ? [path.join(root, "packages/protocol/fixtures/presentation.v1.json")]
            : [];
    execFileSync(binary, args, {
      stdio: "inherit",
      timeout: 10_000,
      ...(suite === "DiagnosticsChecks"
        ? {
            env: {
              ...process.env,
              SLOPZOOKA_HOME: path.join(temporary, "native-home"),
            },
          }
        : {}),
    });
  }
} finally {
  await fs.rm(temporary, { recursive: true, force: true });
}

execFileSync(process.execPath, [path.join(root, "scripts/test-native-video.mjs")], { stdio: "inherit", timeout: 60000 });
