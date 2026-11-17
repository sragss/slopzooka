# Coordinator reliability review and launcher lag investigation

Follow-up to the voice headset slot and the user's request for a maintainability
pass while the headset is unavailable. Existing production and staged test
processes remain untouched. These changes stay in draft PR #65.

## Confirmed issues and narrow corrections

- **Retry after a lost acceptance reply:** the shared voice flow asks whether a
  new request can start. A status poll reporting the already accepted request as
  running made Retry unavailable. Reproduced with the production Swift voice,
  coordinator state and transport against a lost-reply fixture. Retry now checks
  the immutable command's eligibility separately; a known request can be confirmed
  while Pi is busy, while new utterances remain blocked. The server still checks
  identity and payload and does not dispatch again. No duplicate draft owner.
- **Worker reconnect projection:** native thread states `active`/`idle` were
  exposed directly after reconnect, but the UI expects turn states such as
  `running`/`completed`. Reproduced with the real owned worker/PTY and disposable
  WebSocket protocol peer. Reconciliation now projects from the current/latest
  turn, recovers the first delivery as well as later submissions, and restores a
  result whose completion happened while disconnected.
- **Queued cancellation:** an acknowledged native queue deletion did not change
  the local delivery status. It now marks only that removed delivery interrupted;
  unrelated queued submissions remain queued. The existing scoped-Stop integration
  test exercises this through the protocol peer.
- **Idle UI publications:** unchanged session snapshots, scene observations and
  frontend catalogs triggered `objectWillChange` across launcher/window consumers.
  State owners now compare actual presentation values and publish only changes.
  Preview reconciliation still runs on unchanged catalogs so recovery is not
  suppressed. Native scene identity no longer reassigns identical session metadata
  on every render. Existing remote rename checks remain essential: scene identity
  equality intentionally ignores labels, so metadata compares the full window
  record. No new observation cache, layout owner or persistence mechanism.

## Launcher pointer lag: reported, not yet physically reproduced

The user reports extremely laggy cursor motion over the launcher on its pairing
screen while also connected to the Mac; other windows do not show it. The input
source (Mac Virtual Display pointer versus gaze) and whether it persists after
pairing need confirmation. Do not interpret this as evidence that terminal/media
transport is slow.

Source review found no per-pointer-move state mutation or synchronous network call
in the pairing view. Its focus/code-display task is keyed by selected host, and
hover effects are system-managed. The unnecessary UI publications above are a
confirmed inefficiency, **not proof of the reported lag's root cause**. In
particular, a fresh unpaired host does not run authenticated session/catalog polls.
Do not add a speculative debounce, disable all hover effects or redesign pairing
before obtaining a device trace.

Next slot adds one short observation to the existing conversation/name/unread gate:

1. Keep the user's Mac display/input connection as in the report. On the isolated
   test app, move the pointer across the pairing screen and blank space, then over
   another native SlopZooka window. Note whether lag concerns cursor movement,
   highlights or delayed clicks. Pair normally; repeat on Projects and Settings →
   Connected Mac. No production unpairing or session restart.
2. If lag remains, record 20–30 seconds around the same motion with Instruments
   **SwiftUI** (long body/layout updates and update groups). **Time Profiler** is
   the fallback for main-thread stacks. Templates and CLI syntax are present in
   the installed Xcode (`xcrun xctrace list templates`, `xcrun xctrace help record`).
   Resolve the isolated test bundle's PID first; never attach by `SlopZooka` process
   name because production uses the same executable name.

   ```sh
   xcrun xctrace record --template SwiftUI \
     --device FFA7104B-5972-57E0-B392-05D7A5976599 \
     --attach "$SLZ_TEST_HEADSET_PID" --time-limit 30s \
     --output /tmp/slz-launcher-pointer.trace
   ```

3. Compare main-thread/update spikes with the reported motion. If pointer latency
   remains with quiet app activity, compare gaze and the shared Mac pointer before
   blaming our model/polling code. Keep traces local. The earlier signed rig remains
   available for comparison; a simulator build cannot establish pointer latency.

No new permanent per-frame logging or watchdog is introduced. Use the existing
scoped diagnostics and Xcode profiling to separate render/update work from the
system's input path. Physical verification is pending the user's next slot.

## Local verification

The added lost-reply and worker-reconnect regressions failed before their fixes.
The idle-publication check also failed before cleanup; it now observes zero gateway
publications for a repeated unchanged session snapshot plus focus observation.
The shared catalog check observes zero UI publications while both recovery callbacks
still run. Full native state checks also exercise remote preview renames, explicit
close versus disconnect, restoration and per-window notification acknowledgements.

Local pass: `pnpm lint`, `pnpm typecheck`, `pnpm test` (86/86),
`pnpm test:vision-state`, `pnpm test:terminal-keyboard`, `pnpm format:check`,
`pnpm build:harness` with no generated-asset diff, and `git diff --check`.
Logs are local at `/tmp/slz-coordinator-review-*.log`. Signed artifacts and physical
slot results are recorded separately below; no device performance claim follows
from these checks.
