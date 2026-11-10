# Experiment B: two controlled background tabs streaming to Vision

Status: planned, November 9, 2026. Continuous browser frame delivery and its receiver instrumentation are **not implemented or ready for device testing yet**. Our [owned browser control](2026-11-09-owned-browser-extension-probe.md) and [real terminal/Pi](2026-11-09-runtime-qualification-results.md) tests established control, screenshots and lifecycle, not background video.

Companion experiment: [real simulator-to-gateway integration](2026-11-09-simulator-gateway-live-plan.md). This media experiment is independent and may run first if its Mac preparation finishes sooner. It can use the isolated ProbeViewer; that result will not count as production `WindowGateway` integration.

## Question and bounded scope

Can tabs A and B stay independently controllable and continuously visible in Vision while tab C remains selected and usable on the Mac? Does that remain useful when Chrome is covered by another app? What fails first: page rendering, frame extraction, transport, headset presentation or input ownership?

Use the existing disposable Chrome for Testing profile, owned extension/native host, and loopback fixtures. Record the actual browser version/flags. Do not use personal tabs or install an extension into the user's normal profile for the first run. Stable Chrome installation remains separate qualification.

Start with **two streams**, not a large renderer benchmark. Each fixture shows a distinct A/B label, run nonce, event sequence, small text, editable field and counter. Add a switchable animation/scrolling region to distinguish static-idle behavior from stalled rendering. C is a disposable text editor page where the user can type or leave a caret mid-word. Record logical focus emulation separately from the visibly active Chrome tab and macOS foreground app.

## Select one frame source before the headset slot

First candidate: `Page.startScreencast` on each tab's **existing extension-owned debugger connection**, consuming `Page.screencastFrame` and issuing `Page.screencastFrameAck`. The protocol declares image frames and acknowledgement, with JPEG/PNG options; it does not promise our desired background cadence or efficient inter-frame video. Qualify the actual installed browser. Do not attach a competing debugger or silently switch to a newly opened copy of the URL. [Pinned Chrome protocol source](https://github.com/ChromeDevTools/devtools-protocol/blob/b0d96c6cdf39e5583e67a3762b2815a33154455b/pdl/domains/Page.pdl).

This is an event-driven frame-source test, not another 1 fps screenshot-polling demo. Begin with JPEG into the existing receiver to isolate whether the background source works at all. If it works but JPEG cost is material, add **one** comparison through the existing hardware H.264 encoder and receiver, measuring JPEG decode/re-encode overhead too. Transcoding cannot repair frames Chrome never produced. Keep H.264 as the intended initial video transport; this test does not reopen the codec survey.

Fallback only if the first candidate fails the required hidden-tab behavior: investigate `chrome.tabCapture` for the same targets. It produces a MediaStream, but initiation requires extension invocation and target grants; a service-worker stream ID can be consumed by an offscreen document in supported Chrome versions. Any user activation/setup requirement must be reported as a UX cost, not bypassed or labeled autonomous. It also needs a media bridge not currently implemented. [Chrome tab capture](https://developer.chrome.com/docs/extensions/reference/api/tabCapture).

Do not build both fallbacks speculatively. If neither meets the requirement, record the failure and propose one managed/headless or offscreen-host comparison using the same fixtures. Two native Chrome windows with ScreenCaptureKit are a useful compatibility baseline, but cannot pass the claim of two hidden tabs in one window. The [broader hosting comparison](2026-11-09-spatial-surfaces-without-desktop-windows.md) remains available without committing to a Chromium embedder.

## Small implementation changes

| Addition | Requirement |
| --- | --- |
| Frame subscription in the existing extension | Start/stop media for a granted exact tab; emit target/profile identity, incarnation, document revision where available, frame sequence and dimensions. Map all frame events from the same debugger target used for input. Discard packets from revoked bindings. |
| Bounded media relay | Keep continuous pixels out of model/MCP responses. Forward a separate media subscription through the native bridge to the probe host/receiver. Use bounded latest-frame delivery and explicit flow control; acknowledgements must not create unbounded buffering in the next process. Stop/control must remain serviceable while media is saturated. |
| Stream endpoint and receiver | Reuse the probe's authenticated pinned-TLS framing and JPEG/H.264 presentation. Keep credentials private. Add exact target/generation metadata and receiver counters. The existing receiver's status whitelist/three-second silence logic needs an explicit browser-source state, including healthy static-idle versus unavailable. |
| Fixture and independent oracle | Log synthetic input events and unique nonces at the fixture server. Validate decoded frame content against each target's nonce/counter; packet labels alone cannot prove the image is from the correct tab. Reserve a periodic changing marker for active cadence measurements, and disable it for static-idle cost measurements. |
| Ownership separation | Reuse the current lease owner; do not add a second controller. Record that current browser Stop detaches the debugger and therefore also ends a screencast on it. Initially show that explicit unavailable state. Preserving view-only capture across input Stop is a later ownership refinement, not something the prototype already supports. |

Native messaging is JSON over length-prefixed stdio; Chrome documents different message-size limits by direction. Our bridge has tighter local limits, which remain enforced. Count base64/JSON bytes, bounded queue occupancy and dropped frames, not just JPEG payload size. Do not solve overload by increasing buffers without bound. [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).

Inspect and adapt [the current bridge](../experiments/owned-browser-probe/native-host.mjs), [framing](../experiments/owned-browser-probe/wire.mjs), [lease/event owner](../experiments/owned-browser-probe/extension/worker.js) and [receiver](../experiments/shared-window-probe/Viewer/ViewerApp.swift). The existing relay disconnects on excessive queued bytes; the prior flashing/reconnect failure is a reason to measure sustained flow control before headset use.

## Mac-only readiness gate

1. Record revision, browser/runtime versions, launch flags, source settings, profile identity and run-owned processes. Add no blanket throttling-disabling flags without a separately labeled comparison; they can change the behavior under test.
2. Re-run affected browser ownership/framing tests. Extend meaningful coverage for generation mismatch, oversized media, slow consumer, detach while a frame is pending, Stop priority and no cross-target delivery. Compile the changed native host/viewer and run their framing/queue checks.
3. Capture and decode A/B frames locally with C selected, first one source and then both. Apply independently logged input to each. Observe each mode for about a minute, including idle and changing content. Record actual frames; a successful screencast-start response is insufficient.
4. Repeat with the Chrome window covered by a disposable app. Test minimized separately and label it; covered and minimized are not equivalent. An unsupported minimized state may be an initial product limit without invalidating background-tab support.
5. Introduce a stalled local media consumer; verify bounded memory, prompt Stop admission and that B continues when A is stopped. Restart only the owned connection, rebind explicitly and confirm no replay or frame mix-up.
6. Produce an exact two-stream launch/connect/cleanup recipe and receiver build. If the source freezes or continually reconnects on the Mac, diagnose it here. Do not spend headset time proving a known source failure or present a polling fallback as a pass.

Target a responsive 30 fps presentation during active animation as an experiment setting, not an established API capability or release SLA. Log achieved cadence and gaps. If it delivers substantially less, retain the measurement and identify the limiting stage before tuning resolution or quality. Static pages need not generate repeated identical frames; challenge freshness with a new nonce on resume.

## Vision session

Estimate 15–20 minutes after the readiness gate. Timing is for scheduling only; there is no automatic overall cutoff. Keep the Mac unlocked and awake. There is no need to quit ChatGPT, restart its shared helper, or change power/permission settings.

| Case | What we do | What establishes the result |
| --- | --- | --- |
| B1 — one-stream baseline | Show A at a recorded viewport/raster size; exercise small text, input, scrolling, static and animated phases. | User can read and track changes. Source, relay, decoded/queued frames and visible result agree. Record actual resolution, cadence, bandwidth and resource cost. |
| B2 — independent hidden tabs | Show A and B together while C stays selected. Drive separate labels/counters through their existing browser owners. | Both headset views show their own fresh effects. Active tab C and its field/caret remain intact. Neither source is recreated in another page merely to obtain frames. |
| B3 — laptop use | User types ordinary disposable text in C during deterministic alternating A/B updates. Then cover Chrome with another test window. | User reports no unexpected tab/window activation or stolen keystrokes; C's text/caret and active-tab events corroborate it. Both streams remain live, or the exact unsupported state is recorded. Minimize is a separate optional case. |
| B4 — lifecycle | Navigate/reload A, resize its viewport, then close A while B continues. Reopen an explicitly new A target. | No B pixels/input in A, stale references rejected, viewport/frame dimensions correct, old A frames not shown as the new target. B continues without a new session. |
| B5 — overload, disconnect and Stop | Briefly suspend one owned receiver; reconnect. Stop A during bounded input, then explicitly rebind if continuing. | Queues remain bounded; no backlog playback or mutation replay. Stop state matches current shared-debugger behavior. Record lost frames and recovery time; B remains usable. |
| B6 — actual agents | Run one bounded fixture goal each through real terminal Codex and Pi while both streams remain open. | Independent events, images returned to each model and headset-visible outcomes agree. Record overlapping lifetime versus actual interleaved actions; do not infer concurrent dispatch from two running tasks. |

Cases B1–B5 use deterministic controls to isolate media/input behavior from inference time. B6 verifies real-agent composition, not a new model ranking. If two streams are comfortable, an optional brief four-stream step can expose the next bottleneck; 8/20-page scale and a long soak remain subsequent work.

## Measurements and the choice they inform

Record baseline idle, one stream, two static streams and two changing streams separately. Start with one fixed viewport/raster/quality tuple; change one parameter at a time if the user's reading/scrolling experience needs improvement.

| Metric | Measurement boundary |
| --- | --- |
| Frame cadence and gaps | Source events, relay delivery and receiver decode/enqueue counts separately. Use a changing visual marker to detect repeats/freezes. Static-idle is not automatically stale. |
| Input-to-result | Same-Mac clock from input dispatch to independently verified effect and first decoded frame containing it. Receiver acknowledgement round trip provides an upper bound to that receiver stage. Physical display latency is not proven by enqueue/ack. |
| Headset experience | User verdict on small text, scroll motion, flashing, recovery and two-window comfort. If precise visible latency is necessary, add a synchronized visual measurement; do not subtract unsynchronized clocks. |
| Transport cost | Payload and actual relayed bytes per second per stream, frame sizes, dropped frames, queue maxima and reconnect count. Include base64/JSON and any transcoding stages. |
| Resource cost | Browser process-tree, bridge/host and receiver CPU/memory where available, plus system load/thermal state. Record the tool used and unavailable GPU/power attribution rather than inventing per-stream GPU figures. |
| Desktop interference | Foreground app, selected tab, C's input/caret and user report. Focus emulation must not be confused with physical foreground ownership. |

Correctness requires zero cross-target frames/actions, no unexpected desktop activation, no stale-target input and no replay after recovery. Performance requires a user-judged useful two-stream experience with bounded buffers and measured cost; do not declare a numeric release SLA from one short run. Report pass/fail separately for source feasibility, control composition, subjective UX and capacity.

Decision outcomes:

- **Source and UX work at acceptable measured cost:** keep the existing extension/Chrome route for the first browser integration; carry exact target/media identity into Experiment A's gateway boundary.
- **Source works, JPEG transport costs too much:** test the single H.264 transcode comparison. Record whether extraction or transport dominates before adding infrastructure.
- **Only visible tabs/windows produce useful frames:** state the window-hosting constraint; evaluate tabCapture's explicit setup cost or one managed-renderer alternative. Do not claim background control solved background video.
- **Only one stream is comfortable:** record the limiting stage and retain a one-active-stream initial option. Two passes do not establish an infinite active canvas.

## Cleanup, evidence and readiness for the user

Stop all run-owned screencasts, release debugger leases, close only disposable tabs/profile and stream windows, stop the owned bridge/host and restore the previous foreground app. Confirm no extension, native-host registration or browser process from this run remains outside the isolated setup. Preserve the user's ordinary browser state.

At execution, add a dated results note and sanitized evidence alongside the existing browser reports. Full frames, traces, connection material and profiles stay in ignored local run directories. Keep failed attempts and exact changed settings, with outcomes marked passed, failed, blocked, inconclusive or untested.

| Case | Current status | Result/evidence |
| --- | --- | --- |
| Mac source/relay gate | Not run | Adapter not yet implemented |
| B1–B6 | Not run | Await source gate and receiver build |
| H.264 comparison / four streams | Not run | Conditional follow-up |

For the eventual live slot, the user needs the Vision Pro connected for deployment, permission to open the prepared test viewer, and a few brief visual verdicts. Agent runs handle discovery, connections and fixture actions. Do not ask the user to hunt through stream targets: prepare clearly labeled A/B entries and guide the exact opening steps, or use the production presentation path if Experiment A is ready.
