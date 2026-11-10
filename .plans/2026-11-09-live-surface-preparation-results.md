# Live surface preparation: code and Mac checks

Follow-up: [the physical Vision Pro session has now run](2026-11-09-surface-live-results.md). This note preserves the earlier preparation evidence.

November 9, 2026 (local time). Follow-up to [Experiment A](2026-11-09-simulator-gateway-live-plan.md) and [Experiment B](2026-11-09-background-browser-streaming-live-plan.md). **The first headset cases now have runnable code and signed builds. No new physical Vision Pro result is claimed.** The [runbook](../experiments/surface-live-probe/README.md) contains preparation, launch, agent, operator and cleanup commands; [sanitized evidence](evidence/2026-11-09-live-surface-preparation/results.json) records local artifact hashes.

## What is implemented

- **One simulator provider:** an explicitly selected disposable UDID, owned Appium/WDA session, fresh accessibility tree/screenshots, press/fill/swipe/visual tap, Stop and explicit operator Resume. Continuous device MJPEG feeds the independent media path. Each mutation verifies the device/app and rejects old observation references. A model chooses the actions.
- **Actual gateway integration:** opt-in pairing-protected presentation routes, transient bounded command delivery and live descriptor resolution. `WindowGateway` applies open/close/reload through its existing methods and layout/outbox. `WindowScene` still owns native scene actions. Only stable content IDs persist; stream credentials stay in memory/private run files. The companion launches in its own home/port and creates no PTYs.
- **Two browser sources:** `Page.startScreencast` on the same exact extension debugger targets used for input; one outstanding native frame acknowledgement, bounded relay/receiver queues, target/revision checks and source invalidation. The third tab remains selected. JPEG is the experiment's source/transport, not a change to the intended hardware H.264 production path.
- **Two callers, one tool boundary:** Pi and actual terminal `codex exec` use the same scoped stdio MCP. Images reach the models; continuous pixels travel separately. Pi can keep its connection after a turn with `--hold`. Operator commands cover presentation status/open/close/reload and provider Stop/resume.
- **Device preparation:** signed actual-app Gateway Probe under a separate bundle ID and the existing ProbeViewer. Build/install and launch are explicit. The viewer launcher injects its private connection and opens labeled A/B targets, avoiding the manual stream-picker setup. No device installation occurred during preparation.

This remains a prepared-fixture experiment. It does not provision a project/worktree/terminal, supply a production voice UI, or settle which agent owns computer use. The model runs in a separate Mac process; the companion hosts the presentation API, not a newly embedded Pi service.

## Executed checks

| Check | Result and boundary |
| --- | --- |
| Simulator deterministic smoke | Passed: exact device/app, continuous frames, independently observed Count 0→1, old input rejected after Stop. `run-2UzmO8`: 32 source frames / 4,270,996 JPEG bytes over the short smoke, not a cadence benchmark. |
| Pi simulator task, first attempt | Partial: Draft and counter changed; accessibility switch press returned successfully but left appearance off. Pi reported that failure instead of claiming the goal was complete. `run-Uqfmgu`. |
| Pi simulator visual fallback | Passed in `run-CPjdya`: observe → ineffective accessibility press → observe → screenshot-coordinate tap → observe. Fresh independent WDA source showed switch value 1; a separate TLS receiver obtained 21 frames in a 1.5-second observation and its saved image visibly showed the same nonce and dark UI. Five tool calls, three model images, about 15.5 seconds. Single-run timing only. |
| Browser source and independent receivers | Passed in headed Chrome: two distinct background targets, nonce-labeled decoded images, correct independent labels/counters, selected C and its text/caret retained. `run-U4Uqxc` also stopped A while B continued; browser Stop accurately ends A's shared debugger/capture lease. |
| Pi and terminal Codex over new live MCP | Passed sequentially on A/B in `run-BQ2pmo`: each used ten fixture tool calls, changed its own label/counter/page and received a screenshot. Codex 0.167.0 emitted only MCP/message items and exited 0. This is not evidence of simultaneous model actions or xterm prompt routing. |
| Companion transport | Actual isolated server pairing, catalog, command/poll/receipt flow exercised locally. Deterministic Swift gateway tests cover duplicate delivery and late resolution after close through the real gateway. Fake receiver acknowledgement is not physical scene evidence. |
| Cleanup | Final simulator run exited Appium 0, removed its dedicated WDA/xcodebuild children and shut down the simulator it booted; no matching driver remained. Earlier cleanup missed reparented children, which is why device-specific cleanup was added and rerun. |
| Builds/regressions | 45 companion tests, typecheck, Vision state/gateway/media checks, terminal keyboard, formatting, unchanged regenerated browser assets, full visionOS simulator build, signed Gateway Probe and ProbeViewer builds; six browser/media/MJPEG tests and seven existing Pi harness tests passed. |

The repeatable `--phases --stream-seconds 60` run (`run-LPes8g`) passed three one-minute phases:

| Phase | A / B frames per second | Receiver application traffic |
| --- | --- | --- |
| One animated source | 19.55 / stopped | A: 27.52 MB over 60 seconds |
| Two animated sources | 20.00 / 19.98 | 56.49 MB combined over 60 seconds, about 7.53 Mbps |
| Two static sources | 0 / 0 new image frames | 4,200 bytes per receiver over 60 seconds, status heartbeats only |

There were no relay drops within these sampled phases (one startup drop before sampling). Framed JSON source events cost about 10.08 Mbps combined during the two-source animated phase; the relay removes base64 before receiver delivery. Figures exclude TLS/IP overhead. Source settings were JPEG quality 65, max 1280×960, every third source frame. Two streams returning about 20 fps at that setting is not a measured 30/60 fps claim. Other development processes were running; this was a source/transport check, not a controlled capacity benchmark.

A subsequent Pi task used ten calls and one actual image, with independently logged Counter 2→3 and Settings/label effects. The complete local transcript and image were retained. On its disconnect, A produced no further frames while B delivered 30 frames during a separate 1.5-second receiver check. The browser run then exited normally and removed its isolated setup. Deliberate coverage, physical keyboard interference, headset decoding and display latency remain untested.

## Failures kept in the record

1. Initial simulator startup found SpringBoard after WDA launched. Explicit activation of this prepared fixture after owned driver startup fixed it; no arbitrary app is silently foregrounded.
2. WDA's multipart stream contained extra leading blank lines. The parser rejected it and produced no frames. Trimming multipart separators, with split/coalesced regression coverage, fixed it.
3. A SwiftUI switch's accessibility bounds cover the entire row. A returned click was not a changed switch. Fresh-image visual tap plus observed effect is the working fallback; this is why tool success alone is insufficient.
4. The first browser runner called a nonexistent human-fixture helper; corrected before the recorded source passes.
5. Appium shutdown left device-specific children reparented to launchd. Startup now refuses an existing driver on this dedicated device; cleanup verifies process identity before terminating those children and records survivors.

No automatic lock, shared ChatGPT-helper restart, personal browser access or regular SlopZooka installation replacement was needed.

## What the headset slot still needs to establish

Start with **A1/A2**: pair Gateway Probe to the isolated companion, then ask Pi to present and operate the prepared simulator. Compare its command receipt, native scene state, receiver state, nonce and the user's visible result. The existing refresh cadence can add roughly three seconds before the intent is fetched; this is explicitly a polling experiment. Repeat from a second initial screen state.

Then **B1/B2/B3**: launch the preconfigured two-stream viewer, judge text/motion/flashing, confirm independent changes while typing in C, and deliberately cover Chrome. Covered and minimized need separate verdicts. The longer Mac run measures source/transport; it does not replace these visual checks.

A3–A6/B4–B6 remain acceptance cases. Duplicate/late-response, bounded buffering and Stop have deterministic coverage, but physical scene lifecycle, provider replacement, real-user focus interference, reconnection, concurrent model actions and visible overload need their own evidence. Some fault injections remain operator-driven; there is no claim of a fully automated device suite.

Known prototype limits: browser Stop also ends its view; explicit new lease/run is needed. Simulator Resume is operator-only and rejects unavailable media. A live transport heartbeat is not a fresh image: inspect image/frame changes and challenge a static page with an actual mutation. Sustained hangs without transport failure, clean permission onboarding, cold locked preparation, final video transcoding, CPU/GPU/power attribution, native Mac window binding and arbitrary spatial placement remain unqualified.

Preserve this narrow boundary if the tests pass. There is no new durable coordinator, workspace registry, window persistence owner, Chromium embedder or production dependency in this change.

## Latest-main integration before the headset slot

Merged `origin/main` at `dcb5537` into the prepared test branch on November 9. This includes terminal notifications, neutral glass controls, separate Stop/Close actions, modified-arrow handling, macOS DNS-SD discovery and frontend badge fixes. The only conflict was additive gateway test coverage; both suites were retained. Pre-existing research edits were left unchanged.

The merged tree passed **50 companion tests**, typecheck, Vision state (including both gateway suites), terminal keyboard, formatting, harness regeneration with no further asset changes, and the full visionOS simulator build. Signed Gateway Probe and ProbeViewer artifacts were rebuilt from this tree. No headset install or live physical test occurred. [Merge validation evidence](evidence/2026-11-09-live-surface-preparation/merge-main.json).
