# Physical results: simulator gateway and background browser streams

November 9, 2026, approximately 22:08–22:38 America/New_York. **Both core experiments ran on the physical Vision Pro.** The real gateway presented an agent-controlled simulator; two background Chrome tabs streamed while independent agents controlled them. This establishes the prepared-fixture architecture's feasibility. It does not complete the full fault/performance matrix or qualify a production release.

[Experiment A](2026-11-09-simulator-gateway-live-plan.md) · [Experiment B](2026-11-09-background-browser-streaming-live-plan.md) · [Runbook](../experiments/surface-live-probe/README.md) · [Sanitized evidence and artifact hashes](evidence/2026-11-09-surface-live/results.json)

## Experiment A: actual SlopZooka gateway

Used the actual merged companion and Vision app code (`845f259`, including main through `dcb5537`), with a separate Gateway Probe bundle and isolated companion home/port. The Mac provider bound one explicit disposable simulator UDID, WDA session, input and continuous device MJPEG. The coordinator was a separate Pi process using scoped MCP tools; no production agent service was added.

The user initially paired to the regular companion because both advertised from this Mac. Relaunching Gateway Probe with `-companionHost HOST:PORT` preselected the test endpoint; the user entered its code. The launch script now exposes this as `--host`. The regular SlopZooka application and terminal service remained running.

Pi requested presentation through the paired API and `WindowGateway`, then used observations and actual images to set dark appearance, fill Draft and increment Count 0→2. An accessibility press again had no effect on the switch; a fresh-image tap succeeded. The user saw the simulator streaming. **The preview window was too wide; use an iPhone-shaped default in the final UI.** No sizing change was made during the slot.

The user closed the preview with the headset's window control. The saved desired layout became empty. Resubmitting the original acknowledged open request did not reopen it across two poll intervals. A new request reopened one preview; the user confirmed it was streaming. Closing the launcher then left gateway reload/control available through the preview scene.

A queued-input Stop check rejected the queued press and a subsequent stale press; Count stayed at 2. Local Stop acknowledgement took about 1.8 ms in this one run. This measured admission/revocation, not cancellation of an already-dispatched input.

After explicit Resume, a real terminal Codex instance took over the same simulator from an open fixture dialog, dismissed it, changed Draft to `terminal-handoff-ready`, and incremented Count 2→3. The user confirmed all three effects in the streamed view. It used nine scoped MCP calls and completed in about 43 seconds; Pi's first task used fifteen calls and six images in about 55 seconds. These are single-run task times, not model comparisons.

The owned simulator/WDA provider was then stopped and replaced. The device UDID stayed the same, the session changed, and an old element reference was rejected by the new provider. The operator updated the transient descriptor and reloaded the existing stable preview through the gateway. The user confirmed the replacement simulator streaming at Count 1; the new nonce was `38f7449c`. Recovery was operator-driven, not autonomous model provisioning.

## Experiment B: background tabs and real callers

Used isolated Chrome for Testing 157.0.8103.15, the owned extension/native bridge, and `Page.startScreencast` on the same debugger targets as input. Source settings: JPEG quality 65, maximum 1280×960, every third source frame; observed startup samples were about 20 fps per tab. A/B stayed in the background while the disposable `/human` tab was selected. This did not use native Mac window capture or a Chromium embedder.

**The first headset attempt was black.** The JavaScript sender omitted fields required by the existing Swift `MediaHeader` decoder. Declaration defaults do not make non-optional decoded fields optional. Reproduction with the actual Swift parser failed on missing `width`. The sender now supplies the complete header defaults for JPEG, status and paused packets. A new regression compiles/runs the actual ProbeViewer parser against JavaScript-generated fragmented packets. The headset app did not need replacement for this fix.

One replacement run also failed the synthetic human-field invariant: expected seeded text had extra characters. Its cause was not established; the old and replacement test profiles overlapped at startup. That attempt was retained as failed, then cleaned up. A fresh single-profile run passed the invariant. This is not counted as evidence of safe overlapping profile launches.

After the header fix, the user confirmed **both streams visible and stable**, with a somewhat jumpy bar animation. Pi and terminal Codex then ran concurrently against separate A/B slots, each using ten tool calls and an actual screenshot. Independent fixture events showed each label change, Counter 2→3 and Settings. Tool events interleaved. When terminal Codex exited, B's shared debugger/capture lease ended, while A continued. Preserving view-only capture after caller exit remains an explicit prototype limitation.

The user's first typing started after those short tasks finished. We therefore ran a longer Pi task in A. It completed ten increments, Count 3→13. The human observer recorded **33 field-value changes overlapping that task**, all with the human field focused; the user reported typing stayed in the field. The recorded overlap of actual typing was about 5.5 seconds within a roughly 37-second task. This qualifies that observed overlap, not every keyboard/mouse workflow.

A final fresh run checked coverage. A disposable opaque Mac window fully covered the owned Chrome window; recorded bounds and z-order establish coverage. Both sources accepted an increment and independent receivers decoded 30 fresh frames each during 1.5-second samples. The user reported both browser streams working while Chrome was covered.

**Exact final browser count comparison is inconclusive:** the user reported Count 4, while fixture events, accessibility observations and the captured receiver image showed Count 3. Do not silently reinterpret that report or mark exact final pixel/value agreement passed. Qualitative covered-stream visibility passed; a brief, clearly labeled pixel-identity check remains useful before relying on that stronger claim. The simulator's reported Count 1 matched its oracle.

## Case ledger

| Case | Classification | Evidence / remaining portion |
| --- | --- | --- |
| A1 automatic real-gateway presentation | Passed for prepared fixture | Paired request, acknowledged intent, scene/receiver state and user-visible simulator. No workspace/worktree/PTY provisioning was exercised. |
| A2 model-selected changes | Passed | Pi task plus actual terminal Codex handoff from a dialog; independent state and user-visible results. |
| A3 presentation lifetime | Partially passed | Explicit close persisted, reopen worked, launcherless reload/control worked. Forced control-network disconnect/reconnect remains. |
| A4 duplicate / late resolution | Partially passed | Duplicate request after physical close did not reopen. Deliberately delayed physical resolution remains; deterministic real-gateway regression already covers it. |
| A5 provider replacement | Passed for operator-driven replacement | New WDA session, old ref rejected, same stable preview reloaded; user saw replacement Count 1. |
| A6 Stop / resume | Partially passed | Queued and subsequent input rejected; unchanged counter; explicit Resume worked. Stop after an input has already dispatched remains unqualified. |
| B1 readability / cadence | Partially passed | Two-stream headset experience stable, animation somewhat jumpy. Separate single-stream headset baseline and precise display latency/resource cost remain. |
| B2 two independently controlled hidden tabs | Passed within observed scope | Separate exact targets, independent fixture effects and screenshots, two headset subscriptions, user-confirmed stable streams. |
| B3 typing / coverage | Partially passed | Actual typing overlap retained field focus; covered sources continued. Final exact visual count mismatch remains inconclusive; minimized behavior untested. |
| B4 navigation / viewport / replacement | Partially exercised | Full owned-run replacement and stale target-window dismissal/reopening occurred. Independent navigation/reload/resize and one-target reincarnation while its peer stays live remain. |
| B5 overload / disconnect / Stop | Partially passed | Caller exit ended B while A continued; bounded buffering has regression coverage. The proposed six-second host stall was **not run** after the user asked to wrap up. No live overload/reconnect result is claimed. |
| B6 real agents | Passed for composition | Actual Pi and terminal Codex overlapped with interleaved fixture effects and real images. Exact physical completion-value observation for both agents before B stopped was not separately collected. |

The hands-on session is finished. The unrun portions above are follow-up qualification, not hidden passes. The initial codec comparison, clean permissions, arbitrary native apps, cold locked preparation, sleep/lid behavior and high stream counts were outside this slot.

## UX and architecture implications

1. Keep the existing gateway/persistence ownership. No additional durable window system was needed to present, close, reload or recover this stable content ID.
2. Keep a capture subscription's lifetime separate from an individual agent caller. Current browser lease teardown demonstrates the user-visible cost of combining them.
3. Make stream aspect ratio a presentation hint; the iOS fixture needs a phone-shaped window. Browser reading and animation need a deliberate quality/cadence comparison before settling the production defaults. The JPEG experiment does not replace the intended video-codec work.
4. The user proposed reducing stream cost when attention moves away and restoring useful quality within **500 ms**. Record this as a target to test. Available visionOS attention signals, privacy constraints, hysteresis and measured visible recovery have not been qualified; do not assume access to raw eye gaze.
5. Target setup must be unambiguous and automated. Preselect the exact companion and label surfaces with useful names/identity. The discovery-list mistake and the wire-schema bug consumed avoidable headset time. Cross-language native decoder coverage now prevents the latter regression.
6. Minimize future headset asks: prepare a short scripted sequence with obvious visual markers and collect one verdict per meaningful result. Stop the live slot once its architectural questions are answered; finish logs and fault diagnosis afterward.

The hosted Mac CUA tool failed to initialize in this session. We did not restart its shared helper. Simulator control used the scoped Appium provider; browser control used the owned extension. The coverage fixture used narrow local AppKit code and independent window geometry. These results do not qualify the generic Mac CUA runtime's availability.

The coverage fixture's initial placements were clamped onto another display. We verified actual window bounds/z-order and corrected only our own disposable window's constraint behavior. This is not proof that arbitrary third-party windows can be placed outside their app/display constraints.

## Cleanup and retained evidence

Closed the test preview through the gateway, terminated only the two test headset app processes, stopped all owned browser profiles, media hosts, agent callers and the isolated companion/session service, removed the disposable cover window, and shut down the simulator this run booted. The final WDA cleanup recorded no remaining dedicated driver children. The regular SlopZooka app and terminal service were not stopped. Test apps remain installed for reuse.

Raw model/terminal traces, UI images, pairing/stream credentials and the typed disposable text stay under ignored local `build/` directories. Committed evidence contains sanitized outcomes, source/log/artifact hashes and the exact limits above. Seven browser/media/MJPEG tests passed after the packet fix, including the new actual-Swift decoder regression. No production source changed during this live slot; the merged production tree had already passed its 50 companion tests and required native/build checks.
