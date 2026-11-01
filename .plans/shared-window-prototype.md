# Isolated shared-window and locked-Mac prototype

Status: live feasibility tests completed and owned resources stopped, November 1, 2026. See [live evidence and corrections](shared-window-live-results.md) for actual headset, lock, simulator and transport results. The user authorized takeover and explicitly requested no automatic cutoff; the current host uses manual stop with per-operation limits. Preparation-only statements below are historical.

This is the feasibility gate before integrating the orchestrator. It builds on [platform research](macos-window-streaming.md) and [agent/tool direction](orchestrator-tools.md). “Bulletproof” means repeatable tests, explicit limitations, bounded failures and evidence; one successful stream does not establish reliability on every Mac/OS.

## 1. Questions the demo must answer

1. Can Vision Pro show the exact Mac browser/Simulator target being operated, with readable text and acceptable response time?
2. Can the target be resized, obscured, interrupted and reconnected without wrong-target input, stale imagery presented as live, or manual process cleanup?
3. Does the harness promptly block desktop capture/input when the Mac is locked or its availability is unknown, even if the model tries anyway?
4. While the Mac stays locked and the user is elsewhere, which simulator capabilities actually work: screenshot, automated UI test, dynamic navigation/input, and live device frames?
5. Can each working fallback start after lock, or does it only survive if prepared before lock?

The lock/fallback questions take priority over transport polish. The model should receive capability facts and select a usable path; this demo does not introduce a fixed workflow catalog or a new orchestration framework.

## 2. Small standalone deliverables

Implementation home: `experiments/shared-window-probe/`. The production companion, terminal app, window persistence and orchestration are unchanged. The table below remains the intended acceptance scope; the implementation runbook distinguishes built capabilities from untested or deferred behavior.

| Piece | Minimum behavior |
| --- | --- |
| Signed Mac probe app | Select an owned test window; SCK capture; one hardware encoding path; AX resize/control; permission/desktop/provider status; explicit Start/Stop |
| Native Vision viewer | Present a selected target, connection/capability state and measured stream stats; reconnect; route a small set of target-bound interactions |
| Mac/browser fixture | Visible per-run nonce, incrementing counter, fine text, scroll area, editable text, resize response and a dialog; no personal login |
| iOS fixture + XCTest target | Settings page, toggle, text field, scrolling and rotation; accessibility identifiers; unique per-step nonce; screenshots and assertions |
| Device adapter | Explicit simulator UDID, direct `simctl` screenshots/deep links, prebuilt XCTest execution, and a separately prepared WDA/Appium interaction path |
| Thin CLI/control adapter | Query capabilities, observe/act on the selected target, run the fixture tests, select the display provider, fetch results. Use it from the current coding agent; no embedded Pi/Realtime loop needed yet |
| Bounded runner/evidence report | Deadlines, per-test outcomes, owned-resource cleanup, stage timestamps, screenshots/xcresult, machine-readable summary and human-readable report |

Use a native Swift media path and small process/provider adapters. A short CLI may live in Node alongside the existing tooling, but it must not relay raw video buffers. Keep implementation modules local to the experiment until evidence justifies moving a provider into the companion. Do not build both a custom production transport and a WebRTC stack during this spike.

Start media integration with the H.264/native-receiver approach in the platform document. Use native WebRTC if its visionOS build and hardware codec path are straightforward; otherwise use a clearly labeled, bounded direct-LAN prototype. A TCP prototype can establish capture/codec behavior but cannot settle loss/congestion performance. MJPEG is appropriate for measuring the WDA fallback and diagnostics, not evidence that the main multi-window path is cheap.

## 3. Capability facts, model context, and enforcement

Expose separate state for the host desktop, each provider, and each target. **Lock is not a global “all tools unavailable” flag.** The shell, simulator services and a managed browser may have different availability from the desktop.

An illustrative response after a lock event, before device fallbacks have been probed:

```json
{
  "revision": 42,
  "desktop": {
    "state": "locked",
    "observedAt": "timestamp",
    "signalSource": "mac-session-adapter"
  },
  "target": { "id": "fixture-simulator", "generation": 7 },
  "capabilities": {
    "desktop.capture": { "state": "blocked", "reason": "desktop_locked" },
    "desktop.input": { "state": "blocked", "reason": "desktop_locked" },
    "simulator.screenshot": { "state": "unverified" },
    "simulator.uiTest": { "state": "unverified" },
    "simulator.interact": { "state": "unverified" },
    "simulator.stream": { "state": "unverified" }
  }
}
```

This is an example contract, not a settled naming scheme. Provider status should include its last probe/result, target identity and context (OS/device/provider generation and locked/unlocked state). `available`, `blocked`, `unverified`, `starting`, and `failed` must have distinct meanings. A successful unlocked test does not set `availableWhileLocked=true` forever. Cached success informs planning; live calls still validate their target and provider.

On a lock or unavailable-desktop transition:

- Increment the desktop/control generation, revoke its input ownership, reject queued desktop actions and stop delivering the native window stream. Clear the viewer's queued imagery; show “Mac locked — desktop sharing paused.” A retained diagnostic screenshot must be labeled historical.
- Push the new capability state to the client/agent and include current state in subsequent tool results. Recheck at execution time, since the model may have read old context. Hiding a tool or adding a prompt instruction alone is insufficient.
- Let the model inspect/probe independent providers for the same authorized task. Report exactly what worked; screenshot-only access must not be advertised as interactive control.
- On unlock, re-enumerate/rebind as necessary, obtain fresh observations, and explicitly resume. Do not replay an input queue accumulated while locked.

Proposed demo budget: revoke input on handling the lock signal and reflect state at the viewer/agent within 1 second; verify the measured lock-to-signal delay too. This is an acceptance target, not measured behavior. A provider cannot promise to cancel an action already delivered before the transition; log its timing and observed effect rather than declaring it undone.

### Lock detection itself is a test subject

Apple documents session switching and display sleep/wake notifications, but these are not a complete documented lock-state API. The installed public `CGSession.h` lists console/login keys, not a screen-lock key. Do not treat `sessionDidResignActive` as synonymous with locking, or unchanged frames as evidence of lock.

Hammerspoon's source separately subscribes to distributed `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` notifications. These are useful implementation precedents, **not a public Apple compatibility guarantee**. If the prototype also observes the commonly used `CGSSessionScreenIsLocked` dictionary field, isolate that undocumented lookup in the same small adapter and record what the target OS actually returns. Absence must not silently mean unlocked. [Pinned Hammerspoon implementation](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/caffeinate/libcaffeinate_watcher.m), [Apple session-switch notification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification).

Combine transition notifications, startup/reconnect state sampling, public session/display status and provider health. Conflicting/missing/stale evidence yields `unknown` and blocks desktop-dependent actions until availability is established. Test starting the helper while already locked, restarting it while locked, missed/duplicate notifications, and successful recovery after unlock. If reliable classification requires undocumented behavior, that remains a recorded compatibility risk and an OS-version test obligation; the prototype must not conceal it.

A synthetic “locked” switch is useful for deterministic gating/race tests but never counts as evidence that macOS lock was detected or that an iOS fallback works under real lock. For a real test, record the deliberate operator lock transition and independently observed lock-screen state alongside the adapter log. Appium's `mobile:isLocked` describes the simulated/device iOS lock, not the host Mac lock.

## 4. The other-room simulator fallback experiment

Use one dedicated simulator and the same installed fixture app throughout a continuity case. Keep its UDID/build/session identity in every result and stream label. Three different levels of success matter:

| Path | What a pass demonstrates | What it does not demonstrate |
| --- | --- | --- |
| `simctl io <UDID> screenshot` | Can retrieve a fresh device frame while Mac desktop is blocked | Ability to navigate, type, or keep a low-latency video stream |
| Prebuilt XCTest via `test-without-building` | Can execute an actual UI test and return assertions/screenshots while locked | Arbitrary model-driven interaction or preservation of an existing form/session |
| WDA/Appium observation + tap/type/swipe | Can inspect and operate the simulator through a device automation channel | Efficient transport to Vision until separately tested |
| WDA MJPEG frames | Can show fresh device frames independent of capturing the Simulator Mac window | Equivalent bandwidth/latency to hardware H.264, or that every driver screenshot is fresh |
| Build/unit/non-UI integration tests | Can complete useful verification without desktop UI | That the requested screen or interaction was visually verified |

Apple supports building tests ahead of time and running their `.xctestrun` later. This keeps compilation out of the locked phase. Local Xcode 26.3 help confirms destination, concurrency and test timeout controls. [Apple command-line testing](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).

Appium documents WDA screenshots/streaming and device interaction; it does **not** establish that these work under this Mac's lock state. WDA can reuse an existing listener, so warm and cold starts must be measured separately. Some screenshot configurations use the most recent MJPEG frame; a timestamped response alone does not prove fresh rendering. [WDA streaming](https://github.com/appium/appium-xcuitest-driver/blob/4fc9f05cc26c139922c0e54a03190ea51c9f4e3d/docs/guides/mjpeg.md), [driver capabilities](https://github.com/appium/appium-xcuitest-driver/blob/4fc9f05cc26c139922c0e54a03190ea51c9f4e3d/docs/reference/capabilities.md), [device gestures](https://github.com/appium/appium-xcuitest-driver/blob/master/docs/reference/execute-methods.md).

### Sequence inside each actual lock trial

1. While unlocked, establish the target, show its nonce in Vision, and place a known draft in the app. Record all process/device handles and successful baseline provider probes.
2. Lock the Mac deliberately under the agreed test authorization. Confirm the adapter changes state. Attempt a desktop observation and click through the ordinary tool boundary: both must return the specific block without issuing desktop input.
3. Fetch a device screenshot. Change a fixture nonce through a supported test deep link and fetch again. Assert the expected nonce/visual marker is present; merely comparing hashes or file timestamps is insufficient. This validates screenshot freshness, not UI tapping.
4. Through WDA, attach to the already-running app, discover controls, navigate, tap a toggle, type a new nonce, and read back UI state plus a screenshot. For the continuity case, avoid relaunch/reset so the previous draft remains intact.
5. Display device frames in the same Vision surface, visibly identifying the provider switch. The target UDID stays the same. If live frames fail but screenshots work, report that degraded mode explicitly.
6. Run the prebuilt XCTest case separately, allowing its documented fixture reset/relaunch. Check its assertions and screenshot attachments. Do not use this case as evidence of draft continuity.
7. Retry after stopping only the probe-owned WDA runner while the Mac remains locked. A cached warm session cannot satisfy the cold-start case. If time permits, test launching the app and then booting the dedicated simulator from a stopped state while locked as separate cases.
8. Unlock manually, refresh target observations and restore the native stream. Verify the expected final app state and that stale queued actions never execute.

**User scenario to exercise:** “I'm in the other room. Test the settings screen in the iOS app and show me the result.” The model should discover that desktop sharing is blocked, choose an available device channel, and explain what it actually verified. If only XCTest works, return its report/screenshots. If all UI channels fail, perform relevant non-UI checks if useful and say that UI verification needs an unlocked session. No automatic password entry, lock-setting changes, or pretending a build proved the UI.

The fallback is a measured capability, not a promised magic path. If interactive WDA works only when prewarmed, record that exact limitation; a product relying on it would need explicit prewarming and health management. If no native/mobile UI path works while locked, stop integration of that requirement and evaluate a dedicated test Mac/session or VM as a separate proposal.

### Simulator isolation and setup traps

Use a new named test device, explicit UDID, separate derived-data directory, distinct WDA/MJPEG ports and a fixture-only bundle ID. Do not use the ambiguous `booted` alias: the current machine has multiple booted simulators. Do not reset existing devices, stop unrelated Simulator processes, or reuse a live development app's data.

Appium's `isHeadless=true` documentation says it terminates all running Simulator UI instances. Avoid that mode on the user's working Mac. Keep `shutdownOtherSimulators` disabled. Test with a dedicated device and documented ordinary launch/attach behavior; hiding or closing a chosen window is a separate optional test. Explicitly control reset, app termination and force-launch behavior in continuity cases. [Pinned capability definitions](https://github.com/appium/appium-xcuitest-driver/blob/4fc9f05cc26c139922c0e54a03190ea51c9f4e3d/docs/reference/capabilities.md).

Do not run WDA and an unrelated XCTest UI runner against the same device simultaneously. Sequence them, release the owned automation session, and record provider replacement. The experiment should reveal this exclusivity rather than interpreting runner contention as a lock-state failure.

## 5. Reliability cases and concrete pass criteria

| ID | Test | Pass condition |
| --- | --- | --- |
| R1 | Normal browser and Simulator sharing | Matching target/build/nonce in stream and agent observation; input changes that exact target; two simultaneous streams remain legible |
| R2 | Resize, occlusion and minimize | Resize updates geometry before input; covering does not switch target; minimized capture is marked paused and resumes on restore |
| R3 | Dialog, rotation and keyboard | Actual active UI stays observable; orientation/crop changes invalidate stale coordinates; wrong-target input count is zero |
| R4 | Real lock and unlock | Desktop controls reject after observed lock; model/viewer receive state; no stale action replay after unlock; measured classification delay recorded |
| R5 | Locked-device fallbacks | Separate screenshot, UI-test, dynamic-control and stream results, each proving a fresh expected nonce/action on the correct UDID |
| R6 | Cold start under lock | Status helper and WDA/app restart cases distinguish unknown/blocked/available; warm-session success is not substituted |
| R7 | Disconnect and provider failure | Recover same target or report explicit failure; bounded queues/retries; no silently fresh-looking frozen frame |
| R8 | Permission loss and regrant | Capture and AX/input failures classified independently; recovery uses the same signed probe identity; no reset of SlopZooka's production grants |
| R9 | Model uses stale context | Intentionally issue an old-generation action after lock/reconnect; provider rejects before effect regardless of model wording |
| R10 | Stop/deadline | No new effects after stop; owned resources cleaned up before the slot ends; evidence retained; unrelated resources unchanged |

Proposed measurement targets for review: p95 action-to-visible-response under 150 ms on the agreed LAN, capability transition visible within 1 second after notification handling, and reconnect within 5 seconds once the path is usable. Record actual distributions and readability; exceeding a target is a finding, not a reason to relabel the run. Record capture/encode/decode timing, CPU/memory/network use, selected hardware codec and queue depth. One-way timings need synchronized clocks or an external observation method.

At least three actual lock/unlock cycles, a warm and cold WDA trial, and repeated reconnect/resize cycles are needed before calling the demo reliable on this machine. A longer 20–30 minute two-stream soak and a second configuration are follow-up evidence, not implied by the first slot. Deliberate fault-injection tests can establish honest blocking/recovery even when a fallback is unsupported.

## 6. Implementation order before the live slot

1. Build the fixtures, JSON capability state and target-generation checks. Test gating, stale calls, cancellation and fake provider failures without OS capture or locking. These validate execution behavior only.
2. Build the signed Mac app and Vision viewer. Verify a synthetic video source through encode/transport/decode without capture permissions; add real window capture/control and permissions separately.
3. Build/cache the iOS fixture and its UI tests. Prepare WDA against the selected Xcode/runtime and probe each device API unlocked. Pin package/driver versions in the experiment; do not use a global latest install during the test slot.
4. Implement the lock/session adapter, state reporting, stream pause and rebind. Keep undocumented signals isolated and make unknown state observable. Add helper-started-while-locked to the live run list.
5. Add the bounded runner, artifact manifest, scripted failure cases and cleanup. Run all non-disruptive validation before scheduling the physical-device/lock experiments.
6. Rehearse the happy path unlocked with the designated test targets, then use the time slot for the actual risk questions. Unexpected permission/developer-mode dialogs are setup blockers, not opportunities for automatic approval.

These commands now exist in the [runbook](../experiments/shared-window-probe/README.md): `scripts/build.py`, `scripts/prepare_driver.py`, `scripts/session.py preflight`, `scripts/session.py start --seconds N --lan`, and `scripts/probe.py stop`. Start is a live operation, reserved for the agreed slot. App signing and physical Vision provisioning are still required; compilation does not establish live readiness.

## 7. Preparation and what the user needs to provide

**Implementation prerequisite:** the isolated artifacts in section 2 must be built, signed and rehearsed unlocked before the bounded experiment. If a different session implements this plan, it should report exact commands, app paths, dependency versions and current passing tests back here.

**Machine preparation:**

- Mac on power, an agreed network, and a physical Vision Pro for media validation. A Vision simulator is useful for build/UI checks but cannot establish headset latency, thermals or readability.
- Selected Xcode/runtime, initial developer setup completed, and a dedicated disposable iOS simulator. Current read-only inventory: Xcode 26.3 and an iOS 26.3 runtime are present; do not infer compatibility from the separately installed newer runtime.
- Signed probe app installed at a stable path. Grant its capture and Accessibility access during preparation, and establish Local Network access on both sides. Complete any XCTest developer/UI automation setup while unlocked.
- Prebuilt fixture tests and pinned WDA/Appium prerequisites for the selected device. Neither `appium` nor `idb` was found on the current shell PATH during planning; that is not proof they are absent elsewhere. The XCTest/simctl tier can be prepared independently.
- A way to manually unlock at the planned checkpoints and recover the machine locally if needed. No password needs to be shared with the agent.
- Confirm which interruptions the slot permits: locking, display sleep, app/provider restart, networking interruption and optional lid closure are distinct. Permission for a test slot does not silently authorize logout/reboot, changing security settings or shutting down other work.

**When booking the slot:** provide start/end or duration, which headset is available, and the allowed interruptions. No test starts until that message. The current request is to plan first.

## 8. Time-bounded runbook

Example **45-minute** slot, assuming all artifacts and unlocked setup are ready. Adapt to the actual time granted; protect the final five minutes for cleanup and reporting.

| Time | Priority |
| --- | --- |
| 0–5 min | Preflight, resource manifest, baseline status, actual headset connection and one fresh image/action per provider |
| 5–12 min | R1–R3: real streams, resize/occlusion, input/geometry, establish warm device providers |
| 12–27 min | R4–R6/R9: real lock, blocked desktop calls, screenshot and interactive fallback, separate XCTest test, WDA cold restart, unlock/recovery; repeat critical transition as time allows |
| 27–35 min | R7 and remaining lock-cycle repetitions; prioritize helper restart while locked over optional media tuning |
| 35–40 min | Short two-stream measurements and any explicitly allowed permission-loss test; no long-running new experiment |
| 40–45 min | Stop, cleanup owned resources, preserve evidence, report passed/failed/blocked/untested cases |

A 20–30 minute slot should focus on one real stream, actual lock detection/gating, and the three simulator fallback tiers; defer soak, multiple-stream tuning and permission resets. A slot under 20 minutes is a narrow capability check, not a reliability sign-off. If startup is not ready, use the time to fix preparation and report that live feasibility remains untested.

The runner uses a monotonic deadline, enforces per-command timeouts, stops admission of new work at the cleanup reserve and cancels owned subprocess groups. Suggested initial limits: screenshot 10 seconds, semantic action 15 seconds, prebuilt WDA startup 60 seconds, fixture XCTest case 120 seconds, all capped by remaining slot time. Configure explicit Xcode destination and disable parallel UI runners. A hung provider is a result; do not keep retrying beyond the budget.

Maintain a small run manifest of created devices, processes, streams, ports and artifact paths. Stop only owned processes/sessions, restore only test-induced window changes, shut down the dedicated device if the run created/booted it, and leave the Mac lock state under the user's control. No broad `killall Simulator`, deleting shared derived data, or production TCC reset. If the machine is locked at cleanup, remote cleanup can finish but the report must say manual unlock remains necessary.

## 9. Evidence and decision gate

Each run writes a local artifact directory with configuration/version manifest, monotonic event log, capability transitions, per-case results, screenshots containing fixture nonces, `.xcresult` bundles, media statistics and cleanup outcome. Logs omit pairing credentials and unrelated screen contents. Record the complete test interval's lock state, not just a boolean at test start; a case that finishes after unlock is not a locked pass.

Use outcome categories `passed`, `failed`, `blocked`, `untested`, and `inconclusive`. Missing hardware, expired time and a provider that never became ready are not passes. Non-interactive checks now pass as recorded below; every live matrix case remains untested.

Proceed toward integration only after showing reliable shared viewing/control and enforced unavailable-desktop behavior. If locked iOS interaction succeeds, integrate the verified device provider as an independent capability. If only XCTest or screenshots succeed, expose that narrower fallback honestly. If all UI paths fail while locked, record the product limitation before building the orchestrator around an unsupported promise.

For the user-facing demonstration, end with the actual outcome of the other-room prompt: the verified screen/action or test evidence, which provider performed it, whether the Mac remained locked, and any required next step. The future model chooses how to use these capabilities; the harness enforces target correctness and current availability.


## 10. Implemented preparation and the agent-driven slot

The user subsequently authorized building the temporary probe while other tests continue, and asked Codex to act as orchestrator. The implementation lives entirely in [experiments/shared-window-probe](../experiments/shared-window-probe/README.md). This section records preparation before the subsequently authorized live slot. No production source was changed; current evidence is in the linked live-results document.

The probe exposes dynamic inventory, up to four selected windows/device targets, native H.264 streams, fresh PNG observations, AX element inspection/actions/resize, and separately invocable simulator screenshots, prebuilt XCTest and Appium/WDA. Codex can compose these during the conversation and react to headset feedback; there are no fixed Poncho2 workflows or new durable agent service. Native dialogs can be selected as separate targets. Global keyboard/pointer injection, browser DOM/CDP control and WDA MJPEG display remain extensions to evaluate, not existing features.

Preparation evidence, November 1, 2026:

| Check | Outcome | Scope |
| --- | --- | --- |
| Mac host and Vision viewer | Passed compilation | macOS 15+/visionOS 26+; no app launch or hardware deployment |
| iOS fixture and UI tests | Initial app build passed, but test manifest was empty | This preparation claim was corrected during the live trial; actual tests subsequently built and executed, with assertion failures recorded |
| Capability, media and HTTP checks | Passed | Unknown/lock/deadline gating; stale generation; fragmented frames; bounded receiver; incomplete/duplicate/pipelined requests |
| Synthetic codec | Passed four-frame H.264 encode/decode | Hardware required at creation; readback unsupported (-12900), documented separately |
| Python CLI checks | Five passed | Pin checked before bearer token; budget reserve; loopback adapter; owned child deadline/cleanup |
| Appium/WDA | Dependencies installed locally; module imports; WDA build-for-testing passed | Appium 3.9.0, XCUITest 12.22.4, WDA 16.17.6; pinned lockfile; no server/device session launched; vendor warnings retained |
| Capture/AX/TLS over LAN/headset/lock/fallback | Untested | Reserved for setup and the user's slot |

The first attempted driver version was newer than the machine's package release-age policy allowed. Preparation selected the compatible older 12.22.4 release rather than changing that policy. No global driver install or npm configuration change was made. Appium supports project-local dependency loading; the runner uses that route. [Appium dependency management](https://appium.io/docs/en/latest/guides/managing-exts/). WDA was prebuilt separately from execution. [Prebuilt WDA](https://appium.github.io/appium-xcuitest-driver/latest/guides/run-prebuilt-wda/).

The Mac and fixture build uses Xcode 26.3; the test fixture's SDK is iOS 26.2. Runtime behavior on the chosen simulator and physical headset remains a live check. The Mac host is not yet developer-signed; its stable identity, permission grants and Vision provisioning are setup prerequisites. The TLS identity stays in the private local run directory and is imported into process memory only.

Known boundaries to evaluate explicitly: direct TCP/TLS lacks production congestion adaptation; native resolution/fps/bitrate are currently fixed bounds, not a performance sweep UI; the simulator fallback viewer sends diagnostic PNGs; desktop lock evidence uses isolated undocumented signals; absence of that evidence blocks desktop operations unless a local 30-second diagnostic lease is granted. Continuous-clock deadlines include sleep. AX and external vendor operations already issued cannot be undone. Viewer silence blanks after three seconds, so a network failure is not an immediate lock-notification guarantee. Device-side WDA cleanup requires live verification.

For maintainability, keep this as a disposable experiment. If it succeeds, extract the narrow capture/control provider and measured lifecycle behavior into the existing companion ownership model. Do not transplant the prototype HTTP parser, pairing flow, fixture plumbing or runner as another permanent control plane. The future UI, global coordinator and terminal MCP should adapt the same production operations. The result of this slot should determine which provider abstractions are needed.

The live slot subsequently exercised signing, permissions, four selected targets, simulator automation and three lock/unlock cycles. See [actual results and limitations](shared-window-live-results.md); the preparation runbook above is not a current statement that live work is pending.
