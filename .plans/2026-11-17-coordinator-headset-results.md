# Coordinator headset slot — 2026-11-17

Status: core device gate passed; two UX fixes identified. User supplied a 13-minute slot beginning approximately
18:17 UTC. Only the separate `com.slopzooka.probe.coordinator` headset app and
isolated companion on port 55431 are involved. Installed production SlopZooka
and its retained session service remain untouched.

Build: `9316f67`. Rig: `~/.slopzooka/test-rigs/coordinator-2026-11-17-ready`.
Raw observations are private `headset-slot.jsonl` and the rig's existing scoped
logs. No credentials or transcripts are copied into this document.

- Separate headset app installed and launched successfully. User allowed/passed
  network pairing and reached Ask at approximately 18:18 UTC.
- First submission was only “use the coordinator fixture”, rather than the full
  requested test action. Pi asked what to do and created no resources. Clarifying
  a missing action is appropriate; “No project or workspace was captured” is
  unhelpful wording when the user has named a workspace. Improve that feedback.
- User was asked to send “Run the Coordinator fixture test and show it here.”


## Observed results

| Check | Result |
| --- | --- |
| Pairing and Ask | Passed in the separate test app |
| Headset request → Pi → owned Codex → normal terminal | Passed; user confirmed terminal visible |
| Native CUA fixture control | Passed: exactly two clicks and `headset-ready`, independently recorded |
| “show it here” intent preservation | Failed: Pi delegated test execution/reporting but omitted preview intent |
| Explicit app preview | Passed: “Show the fixture app on my headset, then increment once” opened the correct titled fixture window |
| Follow-up routing | Passed: same backend/thread/terminal; counter became 3 |
| Physical visual verdict | User confirmed both terminal and preview visible, Counter 3 and `headset-ready` |
| Stop | Passed: user pressed Stop while a real 60-second waiting task was active; that exact turn/delivery became interrupted |
| Resource preservation | Passed: user confirmed both windows remained; layout retained one terminal and one preview; fixture stayed at 3 |

The Stop task was submitted by the operator through the same authenticated
coordinator endpoint, bound to the headset's existing worker; the user pressed
Stop in the headset. Initial execution and the preview/follow-up were submitted
from the headset Ask UI. These are distinct coverage claims.

Core checks finished by 18:25:30 UTC, roughly eight minutes into the 13-minute
slot. User was released from headset interaction, leaving about five minutes.
No production app or production session service was stopped or replaced.

## UX gaps to fix before broad rollout

1. Preserve app-presentation intent when delegating. The first complete prompt
   asked to run the fixture test and show it here, but the actual delegated task
   requested exact command/output/pass-fail only. Native CUA worked; this was an
   orchestration/wording failure, not a capture or network failure. The explicit
   follow-up caused Pi itself to open the existing preview through the shared
   adapter, then queue one increment in the original worker.
2. Replace stale completion/cancellation text. After Stop, coordinator status was
   `stopped`, the worker and matched delivery were `interrupted`, but the earlier
   reply still said it would sleep and report WAIT-FINISHED. Likewise a completed
   worker can leave the earlier “running” acknowledgement visible. Distinguish a
   historical acknowledgement from current activity and make Stop decisive.
3. A named workspace without an action should get a useful clarification, not
   “No project or workspace was captured.” Global selection is expected; resolve
   a supplied name through context before claiming it is absent.

## Scope and evidence

Local Network, one owned Codex worker, one Mac fixture, one native preview.
No new headset evidence for Direct, iOS Simulator, simultaneous native workers,
voice/realtime, wrist UX, arbitrary existing-terminal adoption, reconnect across
HTTP restart, or locked-Mac operation follows from this slot. Those remain prior
independent evidence or later qualification as described in the implementation plan.

Private evidence: rig `headset-slot.jsonl`, `fixture-state.json`,
`stop-test-request.json`, `home/window-layouts.json`, and scoped Mac/session logs.
The worker used thread `01a1eabd-fc13-73c3-a20d-310a93947ae0` throughout. Its first
turn and increment follow-up completed; cancellation turn
`01a1eac1-1adf-7911-8eb9-4cd343ea91cb` was interrupted. No screenshot or transcript
is committed here.

## Subsequent user feedback

The intended input must be voice using the existing terminal voice UX. The
coordinator should be a concise independent window, launchable from both the
launcher and terminal windows. The typed Ask tab is not the target UX. Recorded
in the [next voice-window plan](2026-11-17-coordinator-voice-window.md), which
supersedes the earlier plan's typed launcher surface for the next implementation.
