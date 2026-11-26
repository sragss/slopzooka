# SlopZooka Connection Lab

Connection Lab is a standalone SwiftUI visionOS app for trying SlopZooka’s
launcher connection flow, pairing, Direct, Settings, and related permission
states with fixture Macs. Its app name is **SlopZooka Connection Lab** and its
bundle ID is `com.samragsdale.SlopZooka.ConnectionLab`.

**Prototype snapshot. Expect drift from production.** The initial reference was
SlopZooka at `f563855`. Before using the lab to evaluate what ships today,
compare the relevant production screens and states, update the lab’s local
fixtures and views as needed, and record the refresh in the
[iteration log](CHANGELOG.md). The lab has its own app target, sources, assets,
settings, and sample data.

## Install and run

1. Open [ConnectionLab.xcodeproj](ConnectionLab.xcodeproj) in Xcode 26.3 or later.
2. Select the **ConnectionLab** scheme and an Apple Vision Pro simulator or
   development-enabled Vision Pro running visionOS 26.2 or later.
3. For a headset, select your team in the target’s **Signing & Capabilities**
   pane. If your team requires a different bundle ID, choose one unique to the
   lab. Run with **⌘R** and open **SlopZooka Connection Lab** from Home View. It
   can be installed alongside **SlopZooka**.

An unsigned simulator build from the repo root:

```sh
xcodebuild -project apps/connection-ux-lab/ConnectionLab.xcodeproj \
  -scheme ConnectionLab -sdk xrsimulator -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/slz-connection-lab CODE_SIGNING_ALLOWED=NO build
```

With a single visionOS simulator booted, install and start in a particular state:

```sh
xcrun simctl install booted /tmp/slz-connection-lab/Build/Products/Debug-xrsimulator/ConnectionLab.app
xcrun simctl launch --terminate-running-process booted com.samragsdale.SlopZooka.ConnectionLab \
  --scenario 'Connected on Direct' --surface frontends
```

Use the scenario’s exact menu label for `--scenario`. The optional `--surface`
argument accepts `launcher`, `settings`, `your-mac`, `frontends`, or `ask`.
The Frontends tab requires a connected fixture. Add `--controls` to open the
developer window at launch. The same launch arguments work
under **Edit Scheme → Run → Arguments**.

## Try the flows

First run opens **Connect to a Mac**. Choose a Mac when discovery completes, or
use **Enter address manually**. After pairing, the launcher sidebar shows
**Repos**, **Worktrees**, and **Threads**, with **Frontends** below a divider.
Open the Mac name in the page header to see the connection status.
**Choose Another Mac** opens the setup picker with a back arrow, and **Done**
returns to the same workspace section. Use **Connection options** to switch
methods. The connection screen shows the address, logs, and reload action together. During
reconnection, the header shows the status and keeps the current page in view.
**Settings** in the sidebar contains app preferences.

**Connection options** opens a separate screen with both connection methods.
Use the back arrow to return, or select a method to start a check. **Cancel**
stops a pending connection check or pairing request.

**First-run discovery**, **Multiple Macs**, and **Connected on Local Network**
connect to a reachable fixture Mac two seconds after you select it.
Turn off **Auto-connect fixture Macs** in
Controls to step through pairing from the picker. The pairing presets start
with automatic connection turned off.

Open **Scenarios** from the ornament below the launcher. Move **Connection Lab
Controls** aside to keep the evaluated screen visible. Use the **Scenario** menu
to replace the fixture with a preset, **Show Screen** to jump between surfaces
without changing the fixture, and the buttons under **Pending requests** to
complete operations that are waiting. Change a pending request’s outcome before
completing it to inspect a retry or failure.

| Flow | Scenarios and controls |
| --- | --- |
| Local Network | First-run discovery, no or multiple Macs, denied or failed Bonjour, manual hostname/IP, invalid address, unreachable Mac, protocol or identity mismatch, connected, and reconnecting. Set **Bonjour discovery result** and choose **Restart Bonjour Discovery** to model permission recovery. |
| Pairing | Complete discovery, choose a Mac, and complete the connection check. Enter **123456** for success or another six-digit code for rejection. Complete the pairing request, then the authenticated connection check. The code window, wrong code, rate limit, network interruption, and revoked pairing can each be staged directly. Expand **Sample addresses** for both fixture Macs. |
| Direct | Try Direct before pairing or with missing trust, or simulate a nearby paired Mac, an offline peer, unsupported versions, wrong identity, and revoked credentials. **Try Again** stays on Direct. **Use Local Network** switches explicitly. **Simulate Relaunch** tests the saved method within the current fixture. |
| Settings | Change zoom, Option as Meta, and wrist selection. Advance immersive transitions with success, cancellation, or failure. Try **Stop Voice Input**. Open the Mac control for window reload, address, logs, and layout error. The lab counts reload requests in Controls. |
| Permissions and previews | **Ask SlopZooka** starts with a dedicated microphone and speech permission screen when access is needed. Use **Enable Microphone**, then **Complete permission request** in Controls to simulate the response. **Not Now** closes Ask. The Frontends tab shows Screen Recording prompts, unavailable Mac windows, and Direct’s web-preview restriction. |

**Reset Scenario** restores the fixture’s initial state. Terminal zoom, Option
as Meta, wrist selection, and the selected launcher tab are stored in the lab’s
own app container. Fixture pairings and routes are in memory.

## Implementation and limits

The launcher has a compact first-run screen and a two-pane workspace with sample
repos, worktrees, recent Codex threads, and frontends. Select a repo, worktree,
or thread to open a writable simulated terminal. Worktrees are grouped by
repository. Commands such as `git status`
and `pwd` return fixture output. The terminal keeps its transcript in memory, and
frontend previews display local sample content. All transport and permission
outcomes come from the lab model. The lab opens its own native windows and uses
native fields, focus, menus and navigation.

Pairing codes and addresses are fixtures. Live Bonjour, AWDL/TLS, Keychain,
background retry timing, companion code pop-ups, window reload/persistence,
actual system permission prompts, microphone capture, Mac privacy panes, and
immersive/wrist behavior require the production app and appropriate hardware.
Preview rows model availability with sample content.

## Make a UX change

| Change | Start here |
| --- | --- |
| First-run setup, Mac picker, connection options, and diagnostics | [ConnectionHomeView.swift](ConnectionLab/ConnectionHomeView.swift) |
| Sidebar, workspace catalogs, and the Mac control | [LauncherView.swift](ConnectionLab/LauncherView.swift) |
| Presets and simulated discovery, pairing, and reconnects | [LabModel.swift](ConnectionLab/LabModel.swift) and [ScenarioControls.swift](ConnectionLab/ScenarioControls.swift) |
| Sample repos, worktrees, Codex threads, and writable terminals | [WorkspaceFixtures.swift](ConnectionLab/WorkspaceFixtures.swift) |
| Settings, permission states, and frontends | [LauncherSettingsView.swift](ConnectionLab/LauncherSettingsView.swift) and [PermissionViews.swift](ConnectionLab/PermissionViews.swift) |

1. Open the lab scheme and launch directly into the state you’re editing.
   **Multiple Macs** is a quick setup walkthrough. **Connected on Local
   Network** starts in the populated workspace. **Local Network reconnecting**
   exercises recovery without leaving the workspace.
2. Edit the lab's own SwiftUI views or fixtures. The build can run from a copy
   of this directory alone. For a layout change, check the affected state in
   the simulator. For gaze targets, also try the center and edges on Vision Pro.
3. Run the model checks below for state changes and add a dated entry to the
   [iteration log](CHANGELOG.md). Include any intentional differences from
   production that matter for evaluating the change.

Run the standalone model checks from the repo root:

```sh
lab_checks_dir=$(mktemp -d)
swiftc -swift-version 6 -warnings-as-errors -o "$lab_checks_dir/checks" \
  apps/connection-ux-lab/ConnectionLab/LabModel.swift \
  apps/connection-ux-lab/tests/LabModelChecks.swift
"$lab_checks_dir/checks"
```

The Xcode project and shared scheme are checked in. To regenerate the project
after adding or moving sources, run
`xcodegen generate --spec apps/connection-ux-lab/project.yml`.
