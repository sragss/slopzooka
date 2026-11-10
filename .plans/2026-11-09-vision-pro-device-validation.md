# Vision Pro refactor device validation

Run the updated Mac companion and native Vision Pro app together. Target **15–20 minutes after installation** for the core pass; run the extensions only after it passes. Success means the same Mac processes survive, system-restored scenes are reused, explicit close intent stays closed, and each user action takes effect once.

Status: core hands-on pass finished at the wearer’s request; open findings remain before merge. Mac replacement preserved all 14 session IDs, the session-service instance/PID, and host ID. The VP build signed with the Merit Systems team and installed over **SlopZooka Dev** (`com.samragsdale.SlopZooka.dev`), which owns the current saved layout. Its client ID and saved host survived installation. The older main VP app is unchanged. Evidence and rollback bundle are under `/tmp/slz-vp-validation/`.

## Before merge follow-up

- **Control-C fix implemented:** WebKit events with a missing legacy keyCode reproduced the dropped shortcut. Normalize Control letters through the existing xterm path. Automated coverage checks both keyboard modes, all letters, modifiers/composition, read-only ownership, and real foreground SIGINT with the same surviving shell. User waived another physical pass and authorized merge after CI is green.
- **Implemented, awaiting device test:** Workspace/window naming through the existing voice flow and three-part header. Terminal names correctly label individual sessions; workspaces also need recognizable names to identify the group across menus. User requested revisiting this before merging; it is separate from terminal rename behavior.

## Live observations

- **PASS:** Mac replacement preserved the host ID, session-service instance/PID, and all 14 pre-existing session records.
- **PASS:** VP Dev installation preserved its client ID and saved host. Explicit pairing succeeded; cached credentials still need a relaunch check.
- **PASS:** One controlled **New Shell** action created exactly one shell in the Codex workspace. Use that shell as A and its Codex session as B; private IDs are in `/tmp/slz-vp-validation/device-check-results.json`.
- **UNRESOLVED:** Earlier setup produced one Codex plus two shells in a separate workspace; the action sequence was ambiguous. Do not count this as proof of either duplication or correct launch behavior.
- **PASS:** Terminal names reached the Mac as VPA/VPB. A reported shell PID 25719 after the requested keyboard checks; no input problems reported. Voice remains pending.
- **FAIL:** Add URL changed to Cancel without a visible input. The field appeared below the catalog, then moved out of view and lost keyboard focus when selected. URL entry now uses a focused sheet independent of the catalog; confirm on device.
- **PASS:** URL-sheet fix installed over VP Dev. Wearer confirmed the modal and preview work; A/B returned without pairing. Client ID/host, session service, A/B sessions, and shell PID 25719 survived.
- **FAIL:** Room-locked physical positions were not preserved across in-place VP Dev installation and devicectl launch. Wearer confirmed windows were locked before installation. Cause remains unestablished; do not claim placement preservation.
- **PASS:** System-close/reopen of A retained PID 25719; terminal reload and two rapid preview reloads kept placement, with no reported duplication or input trouble. Mac session count stayed 19.
- **PASS:** HTTP/menu companion quit/reopen with launcher closed. VPB/preview reconnected, offline-close of A stayed closed, and the Mac retained the same service instance/PID, all 19 session records, and A shell PID.
- **PASS:** Room-locked VPB recovered in place after removing the headset for about 15 seconds; explicitly closed A and preview stayed closed.
- **PASS:** Persistent voice retained both phrases across a pause; one Send reached A once. Recorder logged exactly one `Alpha bravo` line.
- **PASS:** End Session on B left its retained record `exited`, removed it from desired open windows, and did not create a replacement. A remains usable; all 14 original session records and the original service survive.
- **SKIP:** Focused extensions (second host/origin, long voice/retry, spatial notifications, wrist tracking, HTTPS/HMR) were not run; wearer ended the hands-on pass.
- **Cleanup:** Stopped only the disposable preview server and voice receiver. A and other shells remain running. The temporary saved preview URL remains in Frontends for later removal.
- **Launch-count caveat:** One controlled New Shell action was verified exactly once. Initial setup and one later extra workspace launch had ambiguous user action counts; no duplicate-creation conclusion was established.

## Deployment and baseline

1. **Capture before changing anything.** Record source HEAD plus the working-tree build, installed bundle IDs/signing teams, Mac host ID, session-service instance/runtime, existing session IDs, and the client's layout namespace. Keep logs/results under `/tmp/slz-vp-validation/`; leave pairing codes and bearer tokens out of the record. Note existing window positions and which windows are intentionally closed.
2. **Stage and verify both builds.** Use the existing Mac signing identity and the VP app's existing development team. Verify the signed Mac bundle and run its isolated packaged-app tests. Build for physical visionOS; an unsigned device build is preparation, not an installable app.
3. **Replace the Mac app.** Keep a rollback copy of the installed bundle. Quit only the menu/HTTP companion, install the verified fresh bundle at `/Applications/SlopZooka.app`, and reopen it. Confirm packaged runtime, unchanged host ID, and the same session-service instance and existing sessions. Leave the session service running.
4. **Replace the VP app in place.** Match the active app's bundle ID (`com.samragsdale.SlopZooka.dev` in this run) and signing team. Install over the existing app; do not uninstall or erase app data. Relaunch and verify pairing/client identity and saved layout survive. If signing does not match, resolve that before proceeding.
5. **Set up one reusable fixture.** Use an existing test workspace, one shell **VP-A**, one agent terminal **VP-B**, and one disposable local web preview with a second page for back/forward. Record both session IDs, the shell PID, and the initial session count. Put A and B at visibly different positions. Start a numbered heartbeat in A after the initial keyboard check.

Assistant handles builds, installation, fixtures, Mac restart controls, logs, and session comparisons. The wearer performs gaze/pinch, keyboard/dictation, sleep/room-lock actions, and confirms physical placement and spatial sound.

## Core pass

| ID | Action | Pass condition |
| --- | --- | --- |
| 1 · Connect and launch · 2 min | Launch the updated app. Exercise Projects, Terminals, and Frontends. Open A, then B once; rename B through its title. Add the test preview URL. | Cached pairing works on the existing origin. Project/owner lists load. Each explicit terminal launch creates exactly one session. The name agrees in the window, launcher, and Mac dashboard. Preview listings agree across views of the same Mac. |
| 2 · Input · 2 min | In A, test physical typing, arrows, Backspace, and Return through Mac Virtual Display; request/dismiss the software keyboard and repeat. Enable persistent voice, speak two phrases with a pause, then Send once. | Editing and focus work in both keyboard modes. A retains one draft across the pause; Send reaches A once, never B. Stop releases capture. Repeat a short typing check after each recovery below. |
| 3 · Window intent · 2 min | Close A with the system close control; reopen it from Terminals. Close/reopen the preview. Reload terminal content, then reload the preview twice rapidly. Leave B open and close the launcher. | Same session ID/PID and terminal history; no new PTY or agent. Preview uses one native window and newer content wins. Reload keeps the existing scene. Closing a window does not end its process. |
| 4 · Companion interruption · 3 min | With the launcher closed and heartbeat running, use Mac **Restart Companion**, then **Quit** and reopen the menu app. During one interruption, close A and reload the preview repeatedly. | B recovers without the launcher. The same shell/agent processes survive and output resumes. Preview reconnects to its fresh gateway without duplicate scenes or stale errors replacing success. A's offline close remains closed after reconnect; reopening it uses its original session. |
| 5 · Native lifecycle · 3 min | Place A/B/preview apart, explicitly close the preview, then background/return and sleep/wake or room-lock/unlock. Reopen the launcher afterward. | Disconnect/background never become close intent. A/B session IDs/PIDs and desired layout remain intact; no duplicate windows. The preview stays closed. Record actual placement and any system relocation separately. |
| 6 · Install over existing app · 3 min | Keep A/B open, preview closed, and sessions running. Close the launcher, install the same new VP build over itself, and relaunch; bring a restored content scene forward if the OS allows. | Same client layout namespace, pairing, session IDs, and PIDs. A/B recover once; preview stays closed until explicitly reopened. Reopen it once and verify fresh content. Record placement. WebView-only navigation/cookies and active microphone capture are not persistence guarantees across native process replacement. |
| 7 · End and reconcile · 1 min | End only test terminal B using **End Session**, then refresh/reopen the launcher. If a rename was pending, allow its reply to arrive. Check Mac sessions and window commands. | B is unavailable/removed and does not return on a late reply. A continues. No automatic replacement agent/shell appears; the session count reflects only explicit launches and ends. |

Heartbeat for A, after confirming ordinary keyboard input:

```sh
printf 'VP-A shell=%s\n' "$$"
(i=0; while true; do i=$((i + 1)); printf 'VP-A tick=%s\n' "$i"; sleep 2; done) &
SLZ_VP_HEARTBEAT=$!
printf 'heartbeat=%s\n' "$SLZ_VP_HEARTBEAT"
```

For unambiguous voice delivery counts, temporarily run the following in the shell and count only `RECEIVED:` output, not the terminal's input echo. Ctrl-D exits it before the next shell command.

```sh
python3 -u -c 'import sys; [print("RECEIVED:" + line.rstrip()) for line in sys.stdin]'
```

## Focused extensions

| Case | Action and expected result |
| --- | --- |
| New origin / different host · 3–5 min | Use an address never trusted before; explicit pairing is required. If needed, start a second companion with a temporary home and unused port. Switching hosts shows that host's workspace/frontend catalog while old-host windows remain tied to their original Mac. A failed new address never replaces the accepted route or redirects its pairing code. Stop only this isolated peer afterward. |
| Voice interruption and handoff · 2 min | Dictate for over 55 seconds across the recognition handoff; keep both parts once. Interrupt connectivity during delivery, then Retry: one `RECEIVED:` line. Disconnect retains the draft and pauses capture; recovery requires Resume/Retry. Deny microphone permission and verify actionable recovery. |
| Notifications and immersion · 2 min | With A and B apart, emit `printf '\a'` in each. Chime comes from the correct window; selecting it clears only its unread state. Reconnect/reload stays silent. Enter/exit immersion, use both wrist settings, and open a terminal with the launcher closed. |
| Preview behavior · 2 min | Verify back/forward, an HTTPS preview and certificate trust, and HMR if a development app is available. Native content reload preserves the WebView; a whole-app replacement has a different persistence boundary. |

Do not restart the shared session service or use End All Sessions during this pass. If an older retained runtime lacks a capability, record it separately; updating that service requires deliberately ending its sessions, or testing in an isolated home.

## Build and install reference

Run from the repository root. Supply the device identifier and development team only after confirming the existing VP installation.

```sh
SLOPZOOKA_BUILD_DIR="$PWD/build/device-validation-mac" pnpm build:mac-app
SLOPZOOKA_TEST_APP="$PWD/build/device-validation-mac/SlopZooka.app" pnpm test:mac-app

xcrun devicectl list devices
: "${SLZ_VP_DEVICE:?Set the physical Vision Pro identifier}"
: "${SLZ_TEAM_ID:?Set the matching development team}"
SLZ_VP_BUNDLE_ID=com.samragsdale.SlopZooka.dev
xcodebuild -project apps/vision-client/SlopZooka/SlopZooka.xcodeproj \
  -scheme SlopZooka -sdk xros -configuration Debug \
  -destination "id=$SLZ_VP_DEVICE" -derivedDataPath /tmp/slz-vp-device-derived \
  DEVELOPMENT_TEAM="$SLZ_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$SLZ_VP_BUNDLE_ID" \
  'INFOPLIST_KEY_CFBundleDisplayName=SlopZooka Dev' -allowProvisioningUpdates build
xcrun devicectl device install app --device "$SLZ_VP_DEVICE" \
  /tmp/slz-vp-device-derived/Build/Products/Debug-xros/SlopZooka.app
xcrun devicectl device process launch --device "$SLZ_VP_DEVICE" \
  "$SLZ_VP_BUNDLE_ID"
```

## Results and failure handling

Record each case as **PASS / FAIL / SKIP**, with before/after session IDs and shell PID, observed scene count, and timestamps. A skipped physical check remains unverified. At the first failure, capture the Mac and VP logs, exact triggering steps, and screenshot/placement observation before restarting anything. Fix the owning layer, run its relevant regression checks, then repeat the failed case and core cases 3–6.

Afterward, stop the test heartbeat/preview and end only sessions created for this run. Keep pre-existing sessions intact and retain the previous Mac bundle until the new build passes.

## Workspace/window naming follow-up

Implemented and installed after updating to upstream `dcb5537` (including the glass toolbar, badged globe, and modified-arrow fixes). Preserved the tested shared-client cleanup and Add URL modal. Header now shows the fixed repository name, editable workspace name, and editable window name with the existing rounded glass typography and shared voice rename flow. Workspace defaults use a short UTC creation timestamp; per-tool window defaults are durable and never renumber after removal. Existing custom names remain.

All required automated checks, 48 companion tests, simulator/device builds, and signed Mac packaged-app checks pass. Both apps are installed and VP Dev launched. All 19 session records, the original session service, VPA shell PID 25719, client ID, saved host, and pre-existing workspace metadata survived. Private receipts: `/tmp/slz-vp-validation/naming-results.json`.

Wearer test pending: rename workspace and verify sibling windows/Projects agree; rename a window and verify only it changes; open additional agents in the same workspace and verify stable per-tool numbering. Physical Control-C and placement across installs remain separate open findings.

## Header geometry and legacy rename follow-up

After wearer feedback, default workspace timestamps now use lowercase month names. The header uses full-height vector slash dividers with matching slanted click/hover shapes. The middle highlight fills between the two dividers; the right highlight reaches the outer rounded edge. Short and long labels were rendered in all hover states; this caught and fixed a top gap caused by baseline alignment on long labels.

The older restored workspace remains present and valid. Its rename overlay failed to open on device; the exact original state was not captured. Metadata naming no longer depends on PTY/WebView input readiness or input focus. Native checks cover opening the naming overlay with unavailable legacy terminal input, while dictation remains blocked and background still pauses capture. Device recheck remains pending.

All required checks and signed package checks pass. Both apps rebuilt for installation; private receipts and visual previews are in `/tmp/slz-vp-validation/header-polish-results.json` and `slz-header-*.png`. Existing sessions/service/shell preserved. Remaining wearer checks: middle/right gaze fill and alignment, and retry naming the older workspace.

## Control-C resolution

A WebKit event carrying `ctrlKey`, `key: c`, and `keyCode: 0` emitted no input before the fix. xterm relies on a legacy letter keyCode for these shortcuts. The existing injected keyboard normalizer now supplies it for Control letters with missing/229 keyCodes, preserving normal ownership and input transport. It also handles physical letter codes when WebKit reports a control character as the key.

The isolated real-PTY test passed without production PTY changes: writing `0x03` through the writable viewer interrupted a foreground Python process and the original shell accepted another command with the same PID. No process-killing shortcut or new endpoint was added. Native-device retesting is explicitly waived by the user for this fix. CI and merge results will be recorded after completion.
