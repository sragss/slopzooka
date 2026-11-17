# Independent coordinator voice gate — 2026-11-17

The user completed the isolated device test and confirmed “Test complete” before
removing the headset. Production SlopZooka and its sessions were not replaced.

## Tested build and evidence

- Code: `2b7e74e`; signed rig `~/.slopzooka/test-rigs/coordinator-voice-2026-11-17-ready`.
- Headset app: `com.slopzooka.probe.coordinator`, Slz Coordinator Test.
- Companion port 55432; host `9bf51051-29dd-4f60-97ea-5c92710116b8`.
- Headset client `85bfc0c3-b31a-46af-b076-52ee0352928d`.
- Worker `6085a3ee7fba3ef5748afba367b1bb0c`, thread `01a1eb45-7d37-7122-b065-90ef89bab838`.
- Local observations: rig `headset-slot.jsonl`, `fixture-state.json`, diagnostic
  files, and `stop-test-request.json`. No credentials or full private traces are
  committed. Worker trace lives in the local Codex rollout for that thread.

## Results

- Separate Ask window opened from the launcher. User enabled/used real speech and
  confirmed the complete requested sentence was sent.
- Spoken fixture request reached Pi and a real Codex worker. The worker performed
  native CUA: exactly two increments and input `headset-ready`, then requested the
  native preview. User confirmed Counter 2, correct input, preview and terminal.
- User closed Ask and launcher and reopened Ask from the terminal successfully.
- Spoken follow-up reused the same worker/thread and reached Counter 3. User
  reported the follow-up/cancel check working. Local observations show no extra
  increment; there was no separate captured discard event, so countdown timing is
  a user verdict rather than independently timed instrumented proof.
- Operator submitted a disposable `/bin/sleep 60` request through the same
  coordinator endpoint. Headset Stop returned HTTP 200 at 20:53:16 UTC and delivery
  `40771a47929a84f2cbb9233874bf60a0`, turn `01a1eb49-0325-7400-b7d4-80bc74c4059a`,
  became interrupted. User confirmed the terminal/preview stayed open at Counter 3.
- The user also explored other spoken requests; this was not a single scripted
  request/reply transcript. Speech delivery and follow-ups remained functional.

## Trace review and failures

1. Window context was insufficient. The captured coordinator replies included
   “59 window sources” and then “0 windows ... in the Vision Pro app,” while the
   actual headset layout contained a terminal and native preview. `context_get`
   lacked that layout; `preview_list` exposed the Mac capture catalog instead.
   Neither reply was evidence of headset scene visibility.
2. Naming was delegated to the wrong layer. Pi sent the worker “Rename this
   worker's terminal window/title to exactly `the nice window`.” The worker checked
   terminal environment, emitted an OSC title escape into a command PTY, inspected
   iTerm via CUA, then claimed the name was set. This did not rename the SlopZooka
   session. The inherited terminal identity and missing coordinator rename tool
   both encouraged the wrong path.
3. The first follow-up CUA call tried an old app handle, then refreshed the fixture
   app before completing the increment. Final state was 3, not a duplicate click.
4. Two test companions advertised the same name. DNS-SD verified the `(2)` entry
   was the new port. Future rigs get an explicit unique discovery name.

The worker rollout contains its public messages/tools. The Pi loop did not persist
its full inference/tool transcript; analysis above uses captured coordinator replies,
HTTP/ownership observations, source inspection and the worker trace, not a claim
that hidden model reasoning was recovered.

## User feedback implemented in the next revision

- One continuous, scrolling conversation; retain the user's full messages and
  concise coordinator replies instead of replacing one response at a time.
- Native Markdown and short correlated worker-result excerpts. Full worker output
  stays in Details/the terminal. Preserve reading position when inspecting history.
- Explicit identity: Ask lives in SlopZooka on Vision Pro, backed by this Mac.
  `context_get` reads this headset's desired content layout and joins its session
  names/workspaces and matching preview sources. Utility panels and gaze remain
  outside that layout; never infer physical visibility from a saved record.
- Direct `window_rename` and `workspace_rename` tools reuse existing owners.
  No worker/CUA/OSC path for naming SlopZooka terminals or native previews.
- Worker guidance includes its SlopZooka workspace/session IDs. Its environment
  no longer advertises the companion's unrelated parent iTerm session.
- Foregrounding a terminal acknowledges its unread indicator through the existing
  gateway observation. Repeated active observations, reload and reconnect do not.

## Next short device gate

1. Speak “How many windows are open here?” with one test terminal and preview.
   Expect two SlopZooka content windows, with no Mac-source count or invented gaze.
2. From that terminal open Ask, say “Name this terminal the nice window,” then
   “Name the fixture preview Login check.” Verify both headers and uninterrupted
   streaming; scroll back through the conversation and ask what it named them.
3. Send a test bell while the terminal is inactive. Bring it to the foreground
   without typing/clicking inside; its unread indicator should clear. A reload
   must not clear an unread alert in a different inactive terminal.

No repeat of streaming discovery, simulator setup, or lock-state testing is needed.
The new conversation layout, header names and actual native foreground event are
the remaining physical observations; local model/API tests do not establish them.


## Local follow-up validation

The live-model `context-smoke.mts` probe passed four checks against disposable
fixtures: two SlopZooka content windows rather than 59 Mac sources; captured
terminal rename; native preview rename; and conversational recall of the chosen
terminal name. It exercises the configured Pi/OpenAI model with real layout-store
writes but substituted session/presence endpoints, not actual headset presentation.

All 86 companion tests pass, including client isolation, same-ID history retries,
per-delivery progress/excerpts, snapshot eviction, bounded model-history continuity,
and direct naming with no worker dispatch. Native state, keyboard/WebKit, lint,
typecheck, formatting, harness parity and simulator/device builds pass. Markdown
was rendered and inspected locally using the actual native Markdown component.

Next-slot bell preparation is scripted in `scripts/coordinator/notification-check.mts`:
`prepare` creates one isolated shell with a stable saved session ID; `open` uses the
existing headset window adapter; `bell` submits one literal bell command through
the normal input endpoint. No production sessions are targeted.

## Staged next-slot rig

- Final code revision `26983bd`; signed rig:
  `~/.slopzooka/test-rigs/coordinator-thread-2026-11-17-final`.
- Discovery name **Slz Ask Test**, companion port **55433**, host
  `b9744301-9fb3-4270-ab9f-2fc8df51e7e4`. Fetch its current LAN address and fresh
  pairing code at the slot; do not reuse a code recorded hours earlier.
- Matching signed headset binary is staged in that directory as
  `Slz Coordinator Test.app` (bundle `com.slopzooka.probe.coordinator`), not installed.
- Companion/session service/coordinator preflight succeeded. A plain fixture shell
  named **Notification-check** is prepared; its ID is in `notification-session.json`.
  It is intentionally not an owned Codex worker: these checks verify direct
  SlopZooka naming and notification ownership without repeating the CUA gate.
- **Slz Thread Fixture** was opened in the background. Its initial counter is 0.
  The Mac reported `locked` during capture preflight; catalog/source resolution
  must be refreshed after unlocking. This is expected capability gating, not a
  verified ready stream while locked. No unlock or headset action was attempted.
- In a disposable predecessor of this rig, the actual bell script advanced the
  real PTY notification sequence exactly once. That preflight shell/service was
  retired; the final shell has no seeded unread notification.
- Signed Mac regression tests pass on the final package. The PR remains draft;
  local checks and live-model probes do not replace the three physical checks.

Operator sequence: install/launch only the isolated test app; pair to **Slz Ask
Test**; use `notification-check.mts open <rig> <headset-client-id>` and the existing
preview adapter to show the exact Slz Thread Fixture source as **Fixture preview**.
There should be two content windows before the count/naming prompts. Use the same
shell for the final foreground-notification check via `notification-check.mts bell`.
The session service's existing name normalization turns “the nice window” into
`the-nice-window`; report the saved name, not an invented literal title. Leave all
production sessions untouched. Expected user time: roughly 3–5 minutes.

## Subsequent cleanup build

The [reliability review](2026-11-17-coordinator-review.md) records fixes for
accepted-request retry, worker recovery/status, and redundant UI publications,
plus the newly reported launcher pointer lag. Its signed **Slz Ask Review** rig
(port 55434, revision `7e4ce05`) is prepared without launching or replacing the
existing rig above. Use that document's pre-slot steps for the latest build.
Pointer latency remains an unverified physical symptom; retain the previous rig
for comparison if profiling is needed.
