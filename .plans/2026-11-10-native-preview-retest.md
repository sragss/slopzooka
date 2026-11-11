# Native previews: second physical slot and delayed-discard follow-up

Local date 2026-11-10; physical interaction approximately **00:24–00:33 UTC on
2026-11-11**. Source candidate `989369774e58475e2e876cf659745de7f0f30204`, isolated
**Slz Preview Test**, draft [#56](https://github.com/sragss/slopzooka/pull/56).
This follows the [hardening preparation](2026-11-10-native-preview-hardening.md).

**Verdict:** readable streaming, source aspect changes, accessible resizing,
remote reopening without the launcher, covered-source freshness, and truthful
Direct messages passed the wearer checks. **Full restoration did not pass:** a
late discard at app startup deleted the reopened Mac preview's desired-open record.
Only iPhone video resumed on the final return to LAN. Keep the feature opt-in and
PR draft. The narrow corrective patch below is locally verified, not yet physically
qualified.

## Observations

| Check | Evidence and verdict |
| --- | --- |
| Pairing and identity | The host address **and ID** selected the isolated companion. Pairing succeeded on the first reported attempt. The app's persisted client ID was adopted from authenticated diagnostics; no client-ID launch override. |
| Initial video | Wearer: “Yes looks good.” Both new previews showed nonce `a26a7f6a`; iPhone was tall. The combined visual/resize/Reload prompt received an affirmative response. |
| Resizing and Reload | Controls were usable; wearer explicitly confirmed resizing changes the size with fixed aspect ratio and accepted that limitation. No separate numerical scale measurement across Reload. |
| Motion | Rhythmic stutter remains. Wearer reports the same stutter in the regular Mac ↔ Vision Pro display connection. Useful comparative observation; it does **not** identify the cause or establish that the network/renderer is faultless. |
| Corners | Square preview rendering exposes black corners around the rounded macOS content. Follow-up: match source-window corner treatment. Not changed during the slot. |
| Explicit close | Mac preview removed from desired layout; iPhone and both original PTYs stayed present. Wearer closed the launcher too. |
| Remote reopen | Same Mac source re-added via the normal layout API. Wearer confirmed it reopened without the launcher, became tall, and both previews were fresh/moving with nonce `f9326efa`; Mac Count 2. Source-only cover was active. |
| Return to wide / Direct | Wearer confirmed wide again, Direct connected, correct unsupported-preview messages, and launcher closed. |
| App restart on Direct | Relaunch had **no launch arguments**. New app instance connected via Direct using the same persisted client ID. Wearer affirmed both ACKs and correct Direct messages. **Caveat:** the new `restart-a` / `restart-b` strings do not appear in the fixture receipt file; do not claim independent backend verification of that manual input. |
| Return to LAN | Wearer: “Only iPhone resumes.” The Mac record had already been removed at startup by a delayed discard; the stale window did not recover. **Fail.** |

Five completed nonempty sender summaries contain **14,644 offered frames**, zero
encoded-frame drops, and no capture-failure stage. Their offered rates are
24.01–24.82 fps. These are sender counts, **not** measured headset display FPS or
interaction latency. The final short post-LAN stream lacks a completed sender
summary because cleanup followed the wearer verdict. Raw frames were not saved.

Both original fixture PTYs and the session-service identity survived the app
restart and mode changes. Operator-generated fresh input before restart was
recorded from PIDs 67367/67368. The final API snapshot still has exactly those two
sessions; the test did not launch replacement terminal processes.

## The restoration failure

The sequence is visible across native logs and revision-checked layout writes:

1. **00:27:26.493**: user Close requests removal of the Mac preview.
2. **00:27:26.743**: native permanent-discard callback follows for that old scene;
   close is acknowledged as layout revision 3.
3. **00:27:40–42**: operator re-adds the same source; revision 4 contains both
   previews and terminals. A new scene and stream appear. Wearer confirms success.
4. **00:30:17.179**: after relaunch, another `dismiss:false` close arrives for that
   same content. It queues a close before connection is ready.
5. **00:30:19.759**: startup synchronizes that close, producing revision 5 with the
   iPhone preview and two terminals, but no Mac preview. Direct itself connects
   successfully and its unavailable messages remain truthful.
6. Returning to LAN cannot resolve the absent Mac record. The user's final visual
   report matches the saved-layout change.

The old native adapter suppresses old-scene discards only when a replacement is in
`connectedScenes`. That is insufficient at cold start: a replacement can still be
archived. Apple's [`openSessions`](https://developer.apple.com/documentation/uikit/uiapplication/opensessions)
includes active and archived sessions. Apple also documents that a permanent
[discard callback](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:diddiscardscenesessions:))
can arrive on the next launch. **Inference:** checking connected scenes alone
explains the observed late close. The failing build did not log the native session
inventory, so the replacement's archived status is not directly proven by that log.

## Corrective change and local verification

- `WindowScene` supplies references from **all surviving OS sessions**, including
  archived ones. It excludes the entire discard batch, so two discarded copies
  cannot incorrectly protect each other.
- `WindowGateway.discardScene` decides whether a surviving same-host/content
  reference supersedes that discard, otherwise performs the existing explicit
  close. There is no new window registry, persisted generation or layout schema.
- Regression: before any replacement view connects, an archived replacement
  preserves its desired record and leaves no stale close in the persisted outbox.
  A genuine final close still persists, and a same-ID window on another Mac does
  not count as a replacement. Existing cold-start real-close tests remain green.
- Bounded native discard diagnostics record counts of discarded, surviving,
  archived and identified sessions. The gateway logs superseded discards.
- The rig's synthetic workspace repository was missing `isPrivate` and
  `owner.avatarUrl`, causing a `/api/workspaces` decode error in the launcher.
  Those fixture fields are corrected and the smoke run passes. This was separate
  from the preview-layout failure.

Local checks and simulator/device builds are recorded in
[sanitized evidence](evidence/2026-11-10-native-preview-retest/summary.json).
The corrected signed headset binary is staged at the existing isolated path.
It has **not** been installed or tested on the headset. Mac streaming bits are
unchanged from this physical slot.

## Prior focused check (now combined with Direct video)

Use the newer [combined Direct-video and restart slot](2026-11-10-direct-native-video.md) next.
The original narrow lifecycle script is retained below for context.

Approximately **two minutes after pairing**, one focused lifecycle test:

1. Operator launches the isolated rig/app, adopts the real client ID, and seeds
   the two previews and terminals normally. Stay on **Local Network**.
2. Wearer closes only the Mac preview. Operator verifies its record is absent,
   remotely reopens the same source, and waits for the replacement scene/stream.
3. Operator restarts only the test headset app with no arguments. Verify the client
   ID and four desired records survive; inspect the new native discard diagnostics.
4. Wearer confirms both previews show a new nonce and moving content after restart.
   No manual reopen, mode toggle, layout repair or injection of open intent after
   restart is allowed to turn a failure into a pass.

Stop on failure. No repeat of the full streaming, resize, cover, Direct or manual
keyboard sequence is needed for this narrow fix. Shipping-identity permission
repair, integrated lock/source loss, capacity/thermals and Direct video retain
their existing later qualification gates. Corner rounding and baseline-comparable
stutter are recorded UX follow-ups, not silently marked resolved.

## Evidence and cleanup

Private raw logs: `/tmp/slz-preview-validation/run-KqK9Hb`, including all rotated
centralized log segments. Operator notes and final snapshots:
`/tmp/slz-preview-hardening/headset-slot`. Committed evidence excludes tokens,
pairing material, unrelated window titles and terminal contents.

Verified the headset test bundle's container before terminating PID 583. Installed
headset SlopZooka PID 320 was separate. Stopped only the owned Mac rig and dedicated
simulator. Original Mac app/HTTP/session-service PIDs 13544/13547/32460 remained
running; the original SlopZooka sessions were not interrupted.
