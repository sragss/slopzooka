# Next coordinator UX: compact independent voice window

Status: user-directed next UX slice after the [headset gate](2026-11-17-coordinator-headset-results.md).
This is the implementation plan, not a description of shipped behavior. The
current test build still has the typed Ask tab.

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

Do not fill the panel with worker cards, tool traces, IDs, or a permanent chat
history. Detailed coding progress stays in the existing Codex terminal. A failed
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

Local coverage: one scene under repeated opens; correct origin context; no retarget
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
