# SlopZooka Terminal Lab

Terminal Lab is a standalone visionOS app for comparing SlopZooka’s terminal
controls with a simulated Codex terminal and shell. It follows the Connection
Lab’s setup: a native window to evaluate and a separate window for experiments
and scenarios. The Home View name is **SlopZooka Terminal Lab** and the bundle
ID is `com.samragsdale.SlopZooka.TerminalLab`.

## Install and run

1. Open [TerminalLab.xcodeproj](TerminalLab.xcodeproj) in Xcode 26.3 or later.
2. Select the **TerminalLab** scheme and a visionOS 26.2 or later simulator or
   development-enabled Apple Vision Pro.
3. For a headset, select your team under the target’s **Signing & Capabilities**.
   If your team needs a different bundle identifier, give the lab its own.
   Run with **⌘R**. The lab has its own container and can be installed alongside
   SlopZooka and the Connection Lab.

To build and launch from the repository root with a single simulator booted:

```sh
xcodebuild -project prototypes/terminal-controls/TerminalLab.xcodeproj \
  -scheme TerminalLab -sdk xrsimulator -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/slz-terminal-lab CODE_SIGNING_ALLOWED=NO build

xcrun simctl install booted /tmp/slz-terminal-lab/Build/Products/Debug-xrsimulator/TerminalLab.app
xcrun simctl launch --terminate-running-process booted com.samragsdale.SlopZooka.TerminalLab \
  --controls
```

Use **Lab Controls** below the terminal to open the separate controls window.
The lab requests placement beside the terminal. You can move either window.
The terminal updates live as you change the arrangement, dictation treatment,
or size. **Show Terminal** reopens it after a close.
**Reset Scenario** restores the sample session, output, and zoom while keeping
the selected experiment and size.

For a repeatable starting view, pass the exact picker labels with
`--arrangement`, `--dictation`, `--size`, `--session`, or `--voice`.
Use `--popover actions` or `--popover frontends` to open a popover at launch.
The same arguments work under **Edit Scheme → Run → Arguments**.

```sh
xcrun simctl launch --terminate-running-process booted com.samragsdale.SlopZooka.TerminalLab \
  --size Compact --arrangement 'Bottom input dock' \
  --dictation 'Tap to review' --voice 'Partial transcript'
```

## Compare controls

| Arrangement | What to look for |
| --- | --- |
| **Menu left, controls right** (default) | The top-left menu starts with Zoom, Previews, Show Terminal Keyboard, Ask SlopZooka, and Open Launcher. Full-size raised-hand Interrupt and red-square Stop circles sit at top right. Compare whether the extra step to previews is worth the simpler chrome. |
| **Original toolbar** | The globe and frontend count sit at top left. Ellipsis, keyboard, labeled Interrupt, and red End sit at top right. End is quick to find and occupies prime space beside routine controls. |
| **Grouped input** | Keyboard and Interrupt share a glass capsule with separate gaze targets. End moves into Session actions. Compare the ease of switching input actions and the visibility of End. |
| **Quiet toolbar** | Interrupt and Session actions remain visible. Keyboard and End move into the popover. Compare the extra step for keyboard against the extra room at compact widths. |
| **Bottom input dock** | Keyboard and Interrupt move to a native ornament beneath the terminal. End is in Session actions. Compare the shorter eye movement from the prompt against the added vertical footprint and distance from top-right actions. |

The dictation treatment is independent. **Hold and release** uses the
production bottom-right mic, centered draft, partial transcript, and two-second
cancelable send. Hold again during the countdown to add speech. Both treatments
give the transcript the space formerly used by the status bar. The mic-sized
X above the mic cancels any open dictation draft, including during the countdown
or review. The countdown uses a progress outline around the transcript. **Tap to review**
keeps the draft near the bottom edge. Tap the mic a second time to review, then
resume, cancel, or send explicitly. Compare how much output stays visible, how
easy the active state is to understand, and the extra action required to send.

| Scenario | How to exercise it |
| --- | --- |
| Connected, read only, connecting, disconnected, failed, ended, reconnect, invalid URL | Change **Terminal**. Compare input availability, the WebView-style read-only badge, center connection notice, failure/ended status, Session Details, and recovery. Reload simulates a brief reconnect. |
| Frontends | Open Previews in the top-left menu or use the globe in other layouts. Switch the catalog between available, empty, starting/stopped, restricted on Direct, and discovery warning. Open a sample frontend window. |
| Terminal actions | Use zoom and reset, keyboard entry, Interrupt, New Shell, Reload Content, Ask SlopZooka, Open Launcher, Session Details, Report a Bug, Close Window, and the End confirmation. Tap the title’s worktree or window segment to try voice naming. |
| Voice | Stage preparation, empty listening, partial or long transcript, release countdown, microphone denial, or failed delivery and Retry. Switch to Disconnected during a draft or countdown, then reconnect. **Start simulated hold** and **Release simulated hold** in Lab Controls are handy for mouse-only testing. |
| Window and notifications | Use Compact (680 × 510), Production (1280 × 832), or Expanded (1480 × 920). Turn on an unread notification and select the terminal to clear it. |

## Implementation and verification

The baseline links the production glass button style, zoom
controls, hold-to-dictate overlay, voice controller, and send sound directly. The terminal
surface is SwiftUI fixture text in production colors and zoom steps. It accepts
local input and displays simulated output. New Shell switches that fixture to
shell content in the same terminal window. The lab’s launcher, coordinator,
preview, and report are local simulations. The lab uses scripted speech through
the production controller’s capture interface, so it needs no microphone,
pairing, companion, PTY, or publishing access. It exercises native popovers,
focus, sheets, hover treatments, and ornaments. Real speech, WebKit input
ownership, gaze and pinch comfort, VoiceOver, spatial placement, and signed
device installation require physical-device checks.

`LabTerminalWindow.swift` owns chrome and menu placement.
`FixtureSurfaces.swift` owns the terminal text and alternate dictation UI.
`LabModel.swift` owns fixtures and simulated responses. To update the checked-in
Xcode project after moving or adding files, run
`xcodegen generate --spec prototypes/terminal-controls/project.yml`.

To run the standalone model checks from the repository root:

```sh
lab_checks_dir=$(mktemp -d)
source_dir=apps/vision-client/SlopZooka/SlopZooka
xcrun swiftc -swift-version 6 -warnings-as-errors -o "$lab_checks_dir/checks" \
  apps/shared/Diagnostics.swift apps/shared/NativeLogFile.swift \
  "$source_dir/TerminalVoiceController.swift" "$source_dir/TerminalZoom.swift" \
  prototypes/terminal-controls/TerminalLab/LabModel.swift prototypes/terminal-controls/tests/LabModelChecks.swift
"$lab_checks_dir/checks"
```
