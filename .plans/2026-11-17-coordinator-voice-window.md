# Next coordinator UX: compact independent voice window

Status: the independent voice window passed its initial physical gate. See [voice results and feedback](2026-11-17-coordinator-voice-headset-results.md). The next revision adds the continuous conversation, explicit SlopZooka context/naming and foreground notification acknowledgement; those refinements await a new device slot.

## Confirmed product requirements

- Voice is the primary coordinator input. Do not retain the tested typed chat
  form as the normal workflow or require a keyboard to complete a request.
- Reuse the terminal voice interaction the user has already refined.
- The coordinator is its own independent, compact window. It must remain usable
  when the launcher is closed.
- Open that same coordinator window from the launcher and from terminal windows.
- Keep its normal presentation concise and minimal.

The prior implementation plan's typed Ask tab was a wiring test. It is superseded
as the intended product surface. Voice and the independent window are the next
slice, not deferred polish after a typed-chat rollout. GPT Realtime is not a
prerequisite: the existing speech capture can deliver settled text to the tested
Pi endpoint while preserving the option to change the voice backend later.

## Proposed interaction

The launcher exposes an **Ask SlopZooka** action instead of a full Ask tab. Terminal
windows expose the same action. Both open/reveal one coordinator utility window;
repeated invocation must not create duplicate conversations or panels.

From the launcher, start with Global context on the selected Mac. From a terminal,
bring that terminal's Mac, workspace and session as context. Show this as a small
context label, with an explicit way back to Global; avoid the large destination
picker as the normal starting interaction. This context behavior is a proposal
based on the launch origin, not a claim that gaze or global focus tracking exists.

Normal contents:

- A short title/context label and the familiar microphone control.
- The live transcript during speech and its cancel countdown after release.
- One brief current response or activity line, with Stop when applicable.
- Details and approval information only when needed or explicitly expanded.

Do not fill the panel with worker cards, tool traces or IDs. Later headset feedback
requires one scrolling conversation with concise Markdown replies; this supersedes
the original latest-message-only presentation below. Detailed coding progress stays in the existing Codex terminal. A failed
operation or approval must still be visible and actionable; minimal presentation
must not conceal an uncertain delivery or required decision.

Reuse the exact hold-to-talk behavior described in the
[Voice Playground](../docs/voice-playground.md): pinch and hold; keep one draft
across pauses and recognition handoffs; settle final words on release; show the
two-second cancellable send countdown; deliver with the existing click/pulse and
transcript fade. Long speech should follow the latest words with the existing
scroll/fade treatment. Do not add a Send button during recording or pauses.
Opening the window alone does not start recording. Obtain permissions before a
hold, as the existing flow does. Keyboard entry, if retained for accessibility,
is secondary and must not be required for the normal test.

Capture the destination when the user begins an utterance and preserve it through
settling, countdown and submission. Opening the panel from another terminal during
an active draft must not silently retarget it. Reveal the existing panel and keep
the draft's context; adopt a new origin only when idle or through explicit user
intent. Switching focus after speech starts cannot redirect the submitted command.

Closing the coordinator cancels its unsubmitted voice capture/countdown; it does
not cancel an accepted worker task. Stop is the explicit cancellation action.
Reopening shows the current coordinator/worker state without resubmission.

## Existing owners to reuse

- `TerminalVoiceController`, `SpeechCaptureController`, and
  `TerminalVoiceControls.swift` already implement the desired capture and feedback
  behavior. Extend their narrow destination/delivery boundary for a coordinator
  request. Keep one shared microphone owner; do not instantiate an independent
  coordinator capture engine or duplicate the countdown/retry state machine.
- A coordinator voice submission uses the existing typed coordinator request API,
  with the voice command's stable ID carried through retry. It never sends speech
  into a PTY or changes terminal dictation into an orchestrator request.
- `WindowGateway` owns the coordinator open/reveal intent and launch context;
  `WindowScene.swift` remains the only native window-action adapter. Declare the
  independent scene in `SlopZookaApp.swift`. Use the launcher's existing utility
  scene pattern; do not create a second terminal/preview registry or persist
  coordinator chat as a fake terminal window. If durable restoration later needs
  a schema entry, extend the existing shared schema and persistence owner.
- Pi remains ephemeral in the Mac companion. The session service, Codex backend,
  preview intent adapter and stream transport remain unchanged for this UX slice.

A terminal launch origin is context, not new control capability. Existing ordinary
terminals still cannot be adopted as owned coordinated Codex workers. Preserve
that distinction: no raw input injection, silent replacement agent, or claim that
opening the coordinator binds an arbitrary terminal. Requests that need such a
binding must explain the limitation or get explicit intent to start a new worker.

## Implementation sequence

1. Add gateway-owned singleton coordinator presentation and launch context, with
   launcher and terminal entry actions. Move the current request/status owner into
   that independent surface and remove the typed Ask tab from the normal launcher.
2. Connect the shared voice interaction to coordinator submission. Preserve
   command IDs, captured host/context, cancellation, permission and retry behavior.
3. Reduce the panel to the normal contents above. Make current state unmistakable:
   historical “started” replies must not masquerade as current activity, and Stop
   must replace the stale “will finish” acknowledgement.
4. Tighten the orchestration instructions identified in the headset test: resolve
   named workspaces from Global and preserve requested app-preview intent when
   delegating. Do not confuse a terminal report with an app preview.
5. Complete local state/build checks, stage the isolated apps, then request one
   short physical voice/window slot. Do not require GPT Realtime or broad window
   architecture changes to establish this interaction.

## Acceptance and next physical slot

Local coverage: repeated opens emit the same scene identity (physical singleton reveal remains a device check); correct origin context; no retarget
while holding/settling/counting down; one delivery after final recognition; cancelled
countdown sends nothing; uncertain delivery reuses its ID; late host replies cannot
replace the current state; one microphone across terminal/coordinator; closing the
panel leaves workers and previews alive. Reuse existing voice tests and add only
new routing/lifecycle regressions.

Physical checks, with no typing required:

1. Open from the launcher, hold and speak a fixture task with an explicit headset
   preview, release and observe the familiar countdown/feedback and result.
2. Open from the terminal; confirm the same compact window appears with useful
   workspace context. Speak a follow-up and confirm it reaches the same worker.
3. Cancel one utterance during countdown; confirm no task is sent. Then exercise
   Stop on an accepted waiting task and confirm accurate feedback.
4. Close the launcher while the coordinator remains usable. Close/reopen the
   coordinator and confirm no duplicate worker, preview or submission.

Judge size, placement, readability, speech timing and ease of invoking it on the
headset. Simulator builds cannot establish those UX properties. Wrist invocation
can reuse the same gateway action later; it is not required by this feedback slice.


## Capability contract for the singular interface

The user explicitly asked whether this should launch/name terminals, connect to
existing workspaces/threads, launch browser windows, dispatch across multiple
workspaces in one pass, and run CUA against a workspace's previews. All five are
the intended command surface. The voice implementation does not by itself prove
or add every underlying capability.

| Capability | Current boundary / remaining work |
| --- | --- |
| Launch/name new work | Existing workspace create/name and owned-worker launch are available. Explicit terminal and native-preview naming now uses the existing session/layout owners through coordinator tools. |
| Existing workspaces/threads | Existing workspaces and owned workers can be reused. The launcher's saved-thread resume is separate from coordinator ownership. Adopting an already-running arbitrary terminal or resuming a saved thread into an owned backend still needs an explicit ownership contract. |
| Browser windows | A coding worker can launch/control a Mac browser through its available tools and request a native preview. Background extension control and a first-class browser lifecycle adapter remain separate qualification. |
| Multiple targets per request | Pi can sequence multiple tool operations, with exact per-worker correlations. That does not grant parallel foreground desktop input; the native worker lifetime limit still applies. Multi-workspace fan-out needs a targeted end-to-end gate. |
| CUA for workspace previews | Native control and preview presentation passed individually and together for one fixture. Reliable multi-workspace targeting requires explicit preview/source association and foreground-input coordination, using existing schemas/owners rather than a second window registry. |

The next headset slot should establish the new voice/window interaction. It is
not a claim that thread adoption, parallel desktop control, or every browser path
is already implemented.

## Implementation notes

- `WindowGateway.openCoordinator` captures origin and emits one utility-scene
  intent. Launcher and terminal actions use it; the scene adapter alone opens the
  constant native scene value. No terminal/preview layout schema was repurposed.
- The shared hold-to-talk controller has an explicit coordinator destination.
  The existing capture, transcript, countdown, cancellation and feedback views are
  reused. Permissions can be granted before the first hold without starting audio.
- Context is protected by the shared voice owner's active mode and submission
  state. Closing cancels unsent speech; uncertain input retains its original UUID
  and context for confirmation. Reopening does not restart the model task.
- Current-request worker IDs are additive response metadata, allowing the compact
  panel to show actual progress/results without presenting an old acknowledgement
  as current activity. Unknown Stop results remain explicit and retryable.
- Global name resolution and app-preview intent preservation are now explicit in
  the coordinator instructions. Their natural-language behavior still needs the
  next physical flow; instruction changes alone are not a new pass result.


## Local verification (2026-11-17)

Passed: TypeScript typecheck, both linters, formatting, native state checks,
terminal keyboard/WebKit regression checks, regenerated harness asset parity,
and visionOS simulator and signed device builds. All 83 companion tests pass, including
regressions for uncertain Stop and preventing a new request from replacing ownership
while cancellation is awaiting confirmation. Native checks exercise final speech,
countdown cancellation, fixed context, same-ID retry after a lost reply, current
worker feedback and late replies.

Local logs are `/tmp/slz-coordinator-voice-*.log`. The isolated signed headset
build is `/tmp/slz-coordinator/voice-vp/Build/Products/Debug-xros/SlopZooka.app`;
Mac staging uses `/tmp/slz-coordinator/voice-mac/SlopZooka.app`. Neither is a
production install. The next rig uses port 55432 and a uniquely identified
**Slz Voice Fixture**, so it cannot accidentally reuse the previous fixture app.

The four-step physical script above remains the acceptance gate. Microphone
permissions, real recognition timing, native singleton reveal, compact readability
and placement have not been claimed from compilation or substituted speech tests.

Signed-bundle regressions also pass: PTY survival across app replacement and
UI/HTTP restarts, private IPC sign-in, HTTPS preview and stalled-startup escalation.
The staged rig is `~/.slopzooka/test-rigs/coordinator-voice-2026-11-17-ready`,
code revision `2b7e74e`, with signed companion, headset and fixture bundles. It has
not been launched or installed. The earlier rig and production sessions remain
untouched. Start this rig only in the next device slot; read its current pairing
code at that time. Build/test logs remain local and contain no committed secrets.
