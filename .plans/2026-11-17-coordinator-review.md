# Coordinator reliability review and launcher lag investigation

Latest signed staging: **Slz Ask Check**, revision `9984b26`, port **55435**;
see the second-pass artifact note at the end. Earlier rig entries are retained
as evidence, not the current slot target.

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

## Signed artifacts for the next slot

Code revision **7e4ce05** passed the full visionOS simulator build, signed headset
build, signed Mac build and packaged Mac regression checks. Build logs use the same
`/tmp/slz-coordinator-review-*.log` prefix.

New isolated rig: `~/.slopzooka/test-rigs/coordinator-review-2026-11-17-ready`.
Its signed apps and fixture are prepared, **not launched or installed**. Name
**Slz Ask Review**, port **55434**, fixture **Slz Review Fixture**, headset bundle
`com.slopzooka.probe.coordinator`. Both app signatures were verified during staging.
The earlier **Slz Ask Test** rig on 55433 remains untouched, including its shell;
production is untouched. This avoids replacing a running executable under its
session service and retains a pre-cleanup build for comparison.

Before the user puts on the headset, start this isolated rig with `rig.mts start`,
create its owner-only `operator.json` from a local pairing (never print the bearer
token), and run `notification-check.mts prepare`. Open the exact fixture path in
`rig.json` in the background and refresh capture availability after Mac unlock.
Install only the test headset bundle when the slot starts. Fetch the fresh code
then. Reuse the three count/name/unread checks from the voice results document;
add the short pairing/connected-pointer comparison above. No fresh real-model or
CUA discovery run is required for this cleanup.


## Second cleanup pass

The previous pass's companion and vision CI jobs passed before this review.
Two further defects were reproduced against the production owners:

- **Delayed Stop could cancel a newer request.** The endpoint previously carried
  only the client identity and cancelled whichever request was current at arrival.
  Stop now captures the visible request ID in the Swift button action, carries it
  through the existing client endpoint, and checks it on the Mac before aborting
  Pi or cancelling any owned submission. An outdated request returns 409 without
  touching newer work. Missing/malformed IDs are rejected; there is deliberately
  no unscoped fallback. This experimental coordinator requires matching companion
  and headset builds, as before. No new operation queue or cancellation owner.
- **Result recovery could lose the outcome or change the answer.** Live worker
  notifications retained the final 6,000 characters, losing the opening outcome
  of a long answer. Thread reconciliation concatenated all progress and final
  messages. Both now retain the beginning of the last agent message, matching the
  concise-first worker guidance and keeping reconciliation consistent with live
  delivery. The existing bounded result remains bounded; the terminal keeps the
  full answer.

Regression coverage includes a real Pi loop accepting two successive requests
before an old Stop arrives, the authenticated HTTP Stop contract, native captured
request/late-action checks, and the real disposable worker process returning a
long final reply after progress messages. A repeated submission ID forces actual
thread reconciliation without dispatching another task. Both new bug regressions
failed before their fixes and pass afterward. No model/API credentials or headset
interaction are needed for these tests. Launcher pointer lag remains pending the
same physical check; this pass makes no further performance claim.

Second-pass local verification: all **87** companion tests pass, along with native
state, terminal keyboard/WebKit, lint, typecheck, formatting and harness asset parity.
The added coordinator regression failed with “Missing expected rejection” before
request-scoped Stop; the worker regression failed because the returned tail lacked
its outcome. Logs: `/tmp/slz-coordinator-review2-*.log`.

Second-pass artifacts: revision **9984b26** passed simulator, signed visionOS,
signed Mac and packaged Mac checks. The latest isolated rig is
`~/.slopzooka/test-rigs/coordinator-review2-2026-11-17-ready`, named **Slz Ask Check**
on port **55435**, with **Slz Ask Fixture** and the same isolated headset bundle.
It is staged and signature-verified, not launched or installed. Apply the existing
pre-slot start/pair/operator-config/notification preparation to this directory.
All older rigs and running applications remain unchanged; the user checklist is
unchanged. Build/package logs use `/tmp/slz-coordinator-review2-*.log`.
