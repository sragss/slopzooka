# Shared window probe

An isolated Mac → Vision Pro experiment, with **Codex as the interactive orchestrator**. Discover real windows, choose targets during the session, share several at once, operate the selected target, and compare what the headset user sees with fresh observations. No app-specific launch recipes or embedded model runtime.

This directory does not change the production companion, wrist launcher, workspace model, or terminal harness. Delete it to discard the experiment. The eventual shared tool interface should wrap proven providers; this prototype is not a new production framework.

The [research reading guide](../../.plans/2026-11-01-agent-surfaces-index.md) links the current architecture and findings. The `scripts/live_*.py` files retain the one-off live-session orchestration, including selected fixture/device identifiers and local ports. They are historical experiment scripts, not portable unattended tests; use the parameterized CLI instructions below when preparing another session. Private run artifacts and credentials remain under ignored `build/`.

## Current evidence

Prepared and tested live November 1, 2026 on macOS 26.5.2, Xcode 26.3, Node 22.20.0. See [live results](../../.plans/shared-window-live-results.md) for scope, failures, measurements and unresolved cases:

- Mac host, physical-device Vision viewer, iOS fixture and iOS UI test bundle compile.
- Swift checks cover deadline/lock/unknown gating, stale generations, media fragmentation, bounded receive queues, and HTTP request parsing.
- Synthetic four-frame H.264 encode/decode passes without screen capture. Creation requires hardware. This Mac's low-latency encoder returns `kVTPropertyNotSupportedErr` (-12900) for the redundant hardware readback property; that limitation is recorded, rather than reported as a positive query result.
- Six Python checks cover certificate pinning before credentials, slot budget, loopback-only Appium access, and owned process timeout/cleanup.
- Appium 3.9.0 and XCUITest driver 12.22.4 are project-local, with a lockfile. WDA 16.17.6 is prebuilt without starting a device; the driver module imports successfully. The vendor build has warnings, so compilation alone does not establish runtime compatibility.
- Developer-signed host/viewer deployed. Three native Mac windows plus an independent simulator stream reached physical Vision Pro. Native AX action/resize and real lock gating were exercised. WDA interaction and continuous JPEG worked with the desktop locked; fresh input also succeeded after display sleep. These are one-machine feasibility results, not a long-run reliability sign-off.
- Three user-controlled lock/unlock cycles completed. In the final cycle the user confirmed both continuous JPEG counter changes while locked and all native views returning after unlock. Owned services/windows were stopped afterward; the disposable simulator remains installed but shut down.
- Initial setup/transport failures and their fixes are retained in the live report. In particular, the original XCTest build had an empty test manifest; the scheme was corrected and the actual test runner built before execution.

## Pieces and limits

| Piece | Implemented behavior |
| --- | --- |
| `ProbeHost.app` | Explicitly armed host with deadline or manual stop; ScreenCaptureKit window discovery/capture, up to four independently selected targets, hardware-required H.264 encoding, private TLS control/stream endpoint |
| `ProbeViewer.app` | Native visionOS viewer; one spatial window per selected target; pinned certificate; native video rendering; bounded input queue; reconnect; blanks display after a three-second stream silence |
| `scripts/probe.py` | Agent-facing status, inventory, share/remove, screenshot, AX inspection/press/value/resize, simulator screenshot stream, bounded prebuilt UI tests, and Appium interaction |
| Fixtures | Optional native Mac window, local browser page, disposable iOS fixture with counter, input, settings, dialog, rotation/scroll UI tests and nonce deep link |
| Evidence | Private JSONL capability/actions/status logs, manually classified case outcomes, PNG observations, XCTest `.xcresult`, JSON report |

Media is native ScreenCaptureKit → VideoToolbox → framed H.264 over TLS HTTP/1.1 → native `AVSampleBufferDisplayLayer`. It targets 30 fps, at most 1920×1440 per window, and 8 Mbps per encoder. Idle windows may produce fewer frames. The network path allows one outstanding send per peer, drops excess independent JPEG/PNG frames and redundant status packets, and resumes H.264 after drops at a keyframe. A send stalled for more than two seconds disconnects the consumer. Status packets do not establish image freshness: compare visible fixture nonce/counter/clock.

This is a **direct LAN feasibility path**. It has no WebRTC congestion control, bitrate adaptation, audio, HDR, Internet relay, or production pairing flow. Multi-stream cost and actual latency need measurement. Sender monotonic timestamps cannot be subtracted from headset time to claim one-way latency.

AX control is window-bound and separate from capture permissions. The prototype exposes `observe`, `press`, `setValue`, and `resize`; it does not yet inject global keyboard/mouse events or implement browser CDP/DOM control. A successful AX return requires a fresh visual/semantic check. Bounds changes are read back because apps can constrain sizing. Dialogs/popovers may be separate windows and require explicit selection.

Simulator fallback is independent: explicit-file `simctl` PNG observations, Appium/WDA source/find/tap/type/swipe, and prebuilt XCTest assertions. PNG polling delivered roughly one frame every three seconds here and is diagnostic only. The continuous WDA MJPEG adapter now feeds the Vision viewer through the same pinned TLS transport. Requested 15 fps produced about 14 fps at the host; 60% scale/quality 25 used roughly 15–20 Mbps. The user confirmed stable viewing after the busy-send fix, and then confirmed a final locked counter-update / unlock-recovery cycle. See the live report for precise locked/display-sleep evidence and remaining gaps.

`deviceMJPEG` accepts only the owned loopback WDA port `http://127.0.0.1:9117`; the CLI records the session UDID. The host does not independently authenticate that port to a device identity. This is an isolated-probe constraint to replace with provider-owned identity/lifecycle management before production.

## Build and inspect without taking over the desktop

From this directory:

```sh
python3 scripts/build.py --codec
python3 -m unittest discover -s scripts -p test_cli.py -v
python3 scripts/prepare_driver.py
python3 scripts/session.py preflight
```

Requires Xcode, XcodeGen, Python 3 and a Node version supported by the pinned packages. Builds run sequentially with two Xcode jobs. `build.py` creates an untrusted local test TLS certificate in private `build/run/`; it does not install trust settings. Runtime PKCS#12 import uses macOS 15+ memory-only import, without adding keys to the login keychain. Dependencies live in `tooling/node_modules`; no global Appium install. Dependency lifecycle scripts are disabled.

Logs and generated apps are under `build/`. The generated Xcode project is `build/SharedWindowProbe.xcodeproj`. Minimum deployment targets are macOS 15, iOS 26 and visionOS 26. The fixture was compiled against the installed iOS 26.2 SDK; actual runtime compatibility is a live check.

For a stable permission identity, run `python3 scripts/build.py --codec --sign` using an existing developer certificate, optionally selected by `PROBE_SIGN_IDENTITY`. Keep the host bundle at the same path. Do this **before** granting Screen Recording and Accessibility. Rebuilding without `--sign` removes the stable developer signature. Signing/provisioning can itself require setup; the live session subsequently used existing development identities for both apps.

Deploy **ProbeViewer** from the generated Xcode project to the physical Vision Pro, choosing the appropriate team and device. A simulator build does not establish headset readability or performance. The command-line build disables signing; hardware deployment must use valid signing. The permission/setup phase belongs before the measured test interval.

## Live slot: agent drives, user evaluates

These are **live commands**, to run only after the user supplies the slot and chosen targets. Keep a few seconds for cleanup. Start with one ordinary window, then choose additional targets based on what we learn.

```sh
# Fixed slot:
python3 scripts/session.py start --seconds 900 --lan
# Or, when explicitly requested (as in this live session):
python3 scripts/session.py start --until-stopped --lan
```

This starts the native host and its process supervisor. Manual-stop mode has no overall cutoff; individual operations remain bounded. It opens the host UI, but does not select a capture window automatically. Grant the separate capture/Accessibility/local-network permissions during setup. The private `build/run/connection.json` is for the local CLI. The host's **Copy viewer connection** button substitutes a reachable Mac address for the headset. Paste that JSON in ProbeViewer and connect; don't put the token into shared notes or logs. A new arm rotates the token and port.

In another terminal or agent tool call:

```sh
python3 scripts/probe.py status
python3 scripts/probe.py windows
python3 scripts/probe.py share WINDOW_ID
python3 scripts/probe.py snapshot TARGET_ID build/run/selected.png
python3 scripts/probe.py command '{"action":"observe","target":"TARGET_ID"}'
python3 scripts/probe.py command '{"action":"resize","target":"TARGET_ID","width":1100,"height":800}'
```

`WINDOW_ID` is the numeric ID from discovery; `TARGET_ID` is the returned runtime UUID. These examples need actual IDs from this run. Open that target in the headset viewer. `observe` returns an observation token and element IDs. Pass those exact values with `press` or `setValue`; after an action, inspect again. The CLI adds the current desktop generation; callers can explicitly supply an older generation to test rejection.

```sh
python3 scripts/probe.py command '{"action":"press","target":"TARGET_ID","observation":"OBSERVATION","element":"ELEMENT"}'
python3 scripts/probe.py command '{"action":"setValue","target":"TARGET_ID","observation":"OBSERVATION","element":"ELEMENT","text":"slot nonce"}'
python3 scripts/probe.py command '{"action":"remove","target":"TARGET_ID"}'
python3 scripts/probe.py watch --seconds 60
python3 scripts/session.py result R01 passed 'Actual target, observation and headset feedback'
python3 scripts/probe.py stop
python3 scripts/session.py report
```

Candidate order is adaptive: browser text/input → native fixture → chosen Simulator window → two/four concurrent windows → resize/occlusion/minimize/dialog → reconnect → lock/fallback. Codex chooses the next useful observation/action, and the user reports clarity, lag, incorrect cropping or missing content. The fixtures are aids, not a required workflow. Sample product prompts remain pending user review in the planning docs.

`stop` disarms capture, clears AX handles, closes the server and cancels owned screenshot jobs. The app's UI can remain after Stop. In deadline mode the outer supervisor closes it at expiry; in manual-stop mode terminate the recorded owned host PID after disarming. A forced crash/termination may leave `connection.json`; inspect its recorded PID before removing that stale file. There is no broad process kill or automatic simulator shutdown.

## Simulator trials, including the locked Mac

Use a **dedicated disposable simulator with an explicit UDID**, agreed during setup. Install/launch the prebuilt `ProbeFixture.app` on that device during the slot, using `xcrun simctl install UDID PATH` and `xcrun simctl launch UDID com.slopzooka.probe.fixture`. Never use the ambiguous `booted` selector. The fixture path is `build/DerivedData/Build/Products/Debug-iphonesimulator/ProbeFixture.app`. The host does not boot or install a device implicitly.

```sh
python3 scripts/probe.py attach-simulator SIMULATOR_UDID
python3 scripts/probe.py snapshot DEVICE_TARGET_ID build/run/device.png
python3 scripts/probe.py command '{"action":"deviceStream","target":"DEVICE_TARGET_ID"}'
python3 scripts/probe.py ui-tests --udid SIMULATOR_UDID --seconds 120
python3 scripts/session.py driver --seconds 600
```

Run `driver` in its own bounded process, then create an Appium session from another tool call:

```sh
python3 scripts/probe.py appium --udid SIMULATOR_UDID --method attach
python3 scripts/probe.py appium --udid SIMULATOR_UDID --session SESSION_ID --method source
python3 scripts/probe.py appium --udid SIMULATOR_UDID --session SESSION_ID --method find --value increment
python3 scripts/probe.py appium --udid SIMULATOR_UDID --session SESSION_ID --method click --element ELEMENT_ID
python3 scripts/probe.py appium --udid SIMULATOR_UDID --session SESSION_ID --method screenshot --output build/run/wda.png
python3 scripts/probe.py appium --udid SIMULATOR_UDID --session SESSION_ID --method detach
```

The `--bundle-id` argument can target another deliberately selected test app. The adapter checks session UDID before input. Local ports are 4727 (Appium), 8117 (WDA), 9117 (MJPEG); a collision is a blocker, not permission to kill another service. No headless mode or shutdown-other-simulators option is enabled. App launch/termination/reset is disabled in session capabilities. Prebuilt WDA is used; startup and helper restart while locked have been exercised. Verify runner cleanup at teardown. Vendor work already in flight may outlive an HTTP timeout, so verify the runner and device state at teardown. The supervisor attempts owned session deletion before terminating its server process group, but does not claim that this proves device-side cleanup.

For freshness, change the fixture's nonce using `xcrun simctl openurl SIMULATOR_UDID 'slz-probe://nonce?value=unique-value'`, then verify that exact nonce in a new screenshot. For interaction, inspect the accessibility tree, change the counter or draft, and verify an independent screenshot. XCTest launches the fixture and intentionally resets its UI state; use the disposable fixture, not an active working app.

Test screenshot-only, prebuilt XCTest, warm WDA, then cold WDA while the Mac **stays locked for the entire operation**. Correlate the capability/event log throughout, not only before/after booleans. A mixed lock/unlock interval is inconclusive. If a provider fails, return that narrower limitation; do not claim it as a working other-room fallback.

## Lock-state caveat and recovery

The monitor isolates undocumented distributed lock notifications, `CGSSessionScreenIsLocked`, and IORegistry `IOConsoleLocked`. The CGSession key was absent while unlocked on this machine; IORegistry supplied the missing evidence. Public session/sleep notifications also block desktop use. Missing evidence yields `unknown`. A local 30-second confirmation lease remains a diagnostic aid. Display sleep currently changes the single desktop state to `unavailable`, even when still locked; the live test records raw console lock separately. Production should expose lock and display availability as separate facts. This is not a documented cross-version lock API guarantee.

On desktop state changes, stream sockets are closed, the generation advances, native capture stops, AX observations are cleared, and old commands fail. After unlock, explicitly `resume` the native target; discovery verifies the original window ID and owner again. Simulator providers remain independently probeable. The viewer's three-second silence watchdog bounds stale display after an unobserved network loss; it is not a sub-second guarantee. Already-issued OS actions cannot be recalled.

No automatic lock/unlock, power-setting changes, TCC reset, or whole-screen capture is included. The user controls the lock transition during the agreed trial. Test startup while already locked, repeated lock/unlock, display sleep and system sleep separately. Test takeover/input contention before broadening to global keyboard control.

## Evidence required before integration

Use the R01–R10 acceptance matrix in [the plan](../../.plans/shared-window-prototype.md). Record each attempt as passed/failed/blocked/untested/inconclusive, with target identity, state interval, exact action, fresh result and headset feedback. At minimum: actual TLS stream to hardware; correct window identity; native action and resize; multiple target independence; reconnect; deadline cleanup; three lock cycles; warm and cold fallback trials. A longer soak and performance sweep follow after the basic risk is resolved.

`build/run/manifest.json`, host event logs, orchestrator notes, images and `.xcresult` are local evidence. Logs deliberately exclude the pairing token, AX text and screenshots unless requested separately. Status inventories can contain selected app/window names. `session.py report` gathers notes; it does not automatically certify correctness or create case passes. Classify each case from its actual evidence. Some live cases have passed, some exposed fixed bugs, and several remain untested; the linked live report is authoritative for this session.

## References

- [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [window lifecycle behavior](https://developer.apple.com/videos/play/wwdc2022/10155/).
- [Hardware-required VideoToolbox creation](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder), [low-latency encoding](https://developer.apple.com/videos/play/wwdc2021/10158/). Hardware creation failure and readback are separate observations.
- [Appium local project dependency loading](https://appium.io/docs/en/latest/guides/managing-exts/), [prebuilt WDA](https://appium.github.io/appium-xcuitest-driver/latest/guides/run-prebuilt-wda/). Dependency versions are pinned here; verify behavior against those installed sources.
- [Platform/permissions research](../../.plans/macos-window-streaming.md), [coordinator/tool direction](../../.plans/orchestrator-tools.md), [test plan](../../.plans/shared-window-prototype.md).
