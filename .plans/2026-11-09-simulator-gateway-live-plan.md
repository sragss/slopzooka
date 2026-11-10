# Experiment A: one agent-controlled simulator in the real Vision app

Status: core physical path demonstrated, November 9, 2026. [Physical results and per-case ledger](2026-11-09-surface-live-results.md) cover automatic real-gateway presentation, Pi/terminal control, close/reopen, launcherless control and operator-driven provider replacement. Several fault cases remain partial or unrun; this is not a completed production acceptance suite.

Companion experiment: [two background browser streams](2026-11-09-background-browser-streaming-live-plan.md). Broader context: [execution architecture](orchestrator-execution-path.md), [agent responsibility decision](2026-11-09-agent-control-ownership.md), and [latest runtime qualification](2026-11-09-runtime-qualification-results.md).

## Question and smallest useful result

Can a typed request cause an agent to select a prepared simulator, show it automatically in SlopZooka on Vision Pro, operate it, and verify that the user is seeing that same instance?

The decisive demonstration is one correlated chain:

```text
typed request → Pi tools in the Mac companion → exact simulator provider
             → presentation intent → existing WindowGateway → stream receiver
             → model-selected input → fresh observation + matching visible result
```

Use the already qualified Pi configuration as the first caller for this experiment. This is a test choice, not a final decision that Pi owns all computer use. Keep provider handlers callable through a thin terminal-agent MCP adapter; do not implement a second orchestration system to prove the first path. A sequential Codex handoff can follow only after the core cases pass.

Use one existing disposable workspace, one explicitly identified simulator and the prepared [iOS fixture](../experiments/shared-window-probe/Fixture/FixtureApp.swift). Start with device-scoped Appium/WDA observation, input and frames. That keeps the three tied to the same device and reuses prior evidence. It **does not qualify native Codex app-handle-to-Mac-window binding**, native input arbitration, cold simulator provisioning or vendor Locked Use.

Suggested test request, scoped to this fixture:

> Show the prepared iOS fixture beside this workspace in Vision. Turn on Dark appearance, put `gateway-A-<run nonce>` in Draft, and increment the counter twice. Leave the result visible.

Run from two different initial states, including a scrolled view or open fixture dialog. The agent receives the goal and scoped tools and chooses navigation from fresh observations. The runner may establish/reset fixture state and check results; it must not perform the requested UI actions for the agent. The broader product prompt catalog still awaits user review.

## Implementation before using headset time

| Addition | Owner and scope |
| --- | --- |
| Paired presentation request/result | Extend the companion connection and shared TypeScript/Swift contract with a bounded command for an existing resource and explicit client identity. Distinguish accepted intent, scene presence, receiver activity, and unavailable client; an RPC success is not proof the user saw a window. |
| Stream-backed preview resolution | Extend the existing preview/schema boundary. Keep `WindowGateway.swift` responsible for open/close/reload/resolution/restoration, `WindowScene.swift` for native scene calls, and the existing layout/outbox for desired windows. Preserve scene IDs where possible. Do not edit layout files directly or add a second window registry. |
| Exact simulator binding | The Mac provider owns the explicit UDID, WDA session, local endpoint and stream source together. Verify session/device association before admitting input and after recovery. The old probe's bare port `9117` is not sufficient identity. A port collision is an error, not authority to reuse or terminate another service. |
| Small transient surface binding | Associate workspace, stable content ID, provider generation, exact device/app and current controlling caller. Keep observation revisions separate from device/session identity. Persist stable content identifiers only; resolve endpoints, pairing credentials and live handles at use time. |
| Provider and receiver adaptation | Reuse the proven device-frame adapter, bounded queues and receiver, but connect them through the production pairing/resolution path. Do not ship the probe's manual token picker as the integration. Use its continuous JPEG path initially to isolate architecture; record that codec explicitly. No PNG polling or model-loop-driven frame cadence. |
| Agent entry and scoped tools | Add typed submission and only the discovery/attach, present/status, observe/input and Stop operations needed for the request. Reuse provider-native input semantics; no universal action language or scripted app recipe. Return actual model-visible images as well as structured results. |

A small deterministic test caller exercises presentation before adding model inference. Keep resource lifetime separate: closing a preview removes presentation/subscription, not its workspace, terminal process or simulator. Stopping the agent revokes further input while leaving a view available for inspection, unless the provider connection itself has failed; report that condition explicitly.

Stop admission and target generations belong in the shared provider boundary. Abort of a model loop alone is insufficient. On target/session replacement, reject stale observations and queued input; obtain a new binding and observation before acting. Never attach by title, URL, a convenient booted device, or an old native app handle.

## Readiness gate on the Mac

Complete these before asking the user to wear the headset:

1. Record the source revision, runtime tuple, exact simulator UDID/app ID, run nonce and existing processes. Use an isolated development home/port and the documented companion setup. Record a rollback path for any headset build replacement; a separate test app identity needs its own pairing and cannot establish restoration of the installed app.
2. Build the actual Vision app and prepared fixture. Prepare the owned WDA session; prove fresh observation, one reversible action and continuous frames refer to the selected device. Do not touch other simulator sessions.
3. Exercise presentation intent with a fake client: duplicate delivery, late completion after close, explicit close versus disconnect, conflict rebasing, recovery without the launcher and no duplicate process creation. Reject old-generation input before dispatch. A fake client is not physical presentation evidence.
4. Verify bounded receiver input, disconnection state and source-generation changes. A source heartbeat must not masquerade as a new image. Record explicit source-unavailable status rather than leaving an old frame labeled live.
5. Run the repository checks required by [CONTRIBUTING](../CONTRIBUTING.md#verify), including Vision state, typecheck, companion tests, terminal keyboard, formatting, regenerated harness assets and a full visionOS simulator build. Complete any native/provider regression checks affected by extraction.
6. Write the exact launch/install/connect/cleanup commands, built artifact paths and owned process list into the local run manifest. The implementation now supplies explicit build, launch and operator scripts; physical acceptance still requires the user.

If these are incomplete when the headset becomes available, report the missing gate. Use a ready browser experiment first if available; do not substitute ProbeViewer success for the real-gateway claim.

## Live sequence

Allow roughly 15–25 minutes of active device checking after preparation; this is a scheduling estimate, not an automatic cutoff. Stop after the named questions are answered. No Mac locking, ChatGPT/helper termination, personal-app control or broad desktop takeover is needed for these cases.

| Case | Action | Required evidence |
| --- | --- | --- |
| A1 — actual presentation | With an existing terminal visible, issue one typed task. Do not manually select the simulator stream in a picker. | The correct preview opens through the gateway. Its run nonce, provider/device identity and visible app match. Record request, scene and receiver acknowledgements separately; user confirms the picture. |
| A2 — model-driven change | Agent performs the fixture task; repeat once from another initial screen state. | Fresh tree/image verifies Draft, appearance and counter delta; the headset user sees the same result. Record any extra instructions or manual navigation needed. |
| A3 — presentation lifetime | Close the launcher while another eligible scene remains active. Close/reopen the preview; then briefly disconnect/reconnect the test client's control connection. | Commands work without the launcher. Explicit preview close remains closed across reconnect. Reopen creates one view of the same content; no extra PTY, simulator or WDA session is created. All-scenes-inactive behavior is reported honestly. |
| A4 — late reply and duplicate | Delay a presentation resolution, explicitly close its intended preview, then release the reply; resend one request ID. | Late work does not resurrect the closed view; duplicate delivery does not create a second window or process. Use the same transport/gateway path as A1. |
| A5 — replacement and freshness | Restart only the owned provider session or fixture instance; retain an old observation/action for a negative check. | Old action rejected; stale media invalidated; reconnection is explicit and new observations precede input. No silent substitution of another simulator/app. Record device/session replacement separately from fixture-app restart. |
| A6 — Stop and resume | During a bounded repeat action, request Stop after the first independently verified effect. Inspect, then explicitly resume with fresh state. | No newly admitted input after provider Stop acknowledgement. Count effects from already dispatched input separately. Preview remains inspectable or accurately reports provider loss; no automatic mutation replay. |

Optional after A1–A6: release Pi's input ownership and let a real terminal Codex MCP client observe and make one bounded change to that same surface. A fresh observation and matching headset result qualify a sequential handoff only. They do not qualify simultaneous native input, busy-session prompt routing or physical human input into the streamed view.

## Measurements and decision

Keep the log small: run/case/request IDs, workspace/content/device IDs, provider generation, actor, operation, effect sequence, stream sequence, scene state and outcome. Keep secrets and raw UI images in ignored local artifacts.

- Measure typed submission to first useful visible action and verified completion. Separate model/tool time from launch, stream startup and presentation time.
- Measure Stop request to acknowledgement and last observed effect, naming already-dispatched effects. A tool timeout cannot prove cancellation.
- Correlate input, independently observed fixture result and receiver frame; retain representative screenshots and user verdict. Enqueuing a frame is not proof of physical display. Use local-clock durations or an explicit round-trip bound; never subtract unsynchronized Mac/headset clocks. Exact display latency needs additional display-timing evidence.
- Ask the user to judge automatic opening, responsiveness, clarity and how understandable Stop/recovery feels. Performance numbers are observations, not a newly invented product SLA.

Advance when A1–A6 have classified evidence, with correct target, no duplicate resource creation, no close resurrection and accurate failure/Stop state. Record model failures as model failures; a deterministic caller can diagnose the plumbing but cannot turn a failed agent task into a pass. If identity or gateway ordering fails, repair that boundary before adding voice or broader workspace launch.

The conclusion should identify whether the missing production boundary is now closed and which adapter code remains necessary. Do not claim final agent ownership, native Mac target safety, headset pointer/keyboard control, cold preparation, arbitrary spatial placement or media scalability from this run.

## Cleanup and journal

Stop the owned agent task, revoke its input, close only test previews through the gateway, stop owned streams/driver sessions, and restore the prior test-app/connection state. Leave existing PTYs and unrelated simulators running. Shut down only a simulator booted exclusively for this run if its preflight state was off. Verify device-side runner cleanup as well as local PIDs; preserve failure artifacts.

At execution, create a dated results note beside this plan and sanitized evidence under `.plans/evidence/`; store full traces/builds locally under ignored run directories. Log every attempt as passed, failed, blocked, inconclusive or untested, including fixes and reruns.

| Case | Current status | Result/evidence |
| --- | --- | --- |
| Mac preparation | Passed within documented scope | [Readiness results and remaining limitations](2026-11-09-live-surface-preparation-results.md) |
| A1–A6 | Executed with partial cases | [Physical case ledger](2026-11-09-surface-live-results.md#case-ledger); forced disconnect, deliberately delayed resolution and already-dispatched Stop remain |
| Optional Codex handoff | Passed | Same simulator, modal dismissal, draft/count changes and user-visible confirmation |

References: [current ownership map](../docs/architecture.md), [repository window invariants](../AGENTS.md#window-architecture), [probe implementation and limits](../experiments/shared-window-probe/README.md), [prior physical results](shared-window-live-results.md).
