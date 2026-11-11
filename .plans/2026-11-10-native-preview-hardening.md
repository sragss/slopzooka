# Native previews: hardening and second headset gate

Follow-up to the [first physical slot](2026-11-10-native-preview-device-results.md),
on draft [#56](https://github.com/sragss/slopzooka/pull/56), stacked on transport
[#54](https://github.com/sragss/slopzooka/pull/54). Feature remains opt-in. This
records local preparation, not a second headset pass.

The slot has now run: [second physical results and focused follow-up](2026-11-10-native-preview-retest.md).
Use that follow-up, not the four-batch script below, for the next slot.

## Changes motivated by the slot

- **Remote reopen:** reproduced a late hidden-scene observation re-arming a
  closed window's presentation flag. The gateway now distinguishes unobserved,
  existing/requested, and explicitly closed scenes. A background-restored scene
  still counts as existing; disconnect/background never writes close intent.
  The regression closes a preview, delivers a late hidden event, remotely adds
  the record, and opens it through another scene's presenter exactly once.
- **Truthful recovery:** window persistence synchronizes paired routes, rather
  than treating every discovered unpaired Mac as a recovery failure. Successful
  catalog refreshes notify the same gateway. An already-restored native scene
  gets the current unavailable reason even before its layout arrives; this does
  not add an open record. Genuine errors on paired routes remain errors.
- **Resize affordance:** the native preview ornament is above the image. Reload
  remains visible; Close Preview is in an actions menu. Physical resize handles,
  scaling through Reload, and comfort still need the headset verdict.
- **Backpressure:** the sender waits for send/ACK capacity before encoding and
  coalesces raw input to the newest image. ACK and send completion resume work.
  There are still at most two unacknowledged encoded frames, one encode in flight,
  and one latest raw buffer. Encoded dependencies are not routinely discarded to
  catch up. Protocol, hardware H.264, and Node's opaque binary forwarding stay the
  same; this adds no playback queue or alternative transport.
- **Capture recovery:** waiting/reconfiguration has its own ten-second deadline,
  rather than comparing a later resize against original stream startup. Missing
  capture activity clears the image into waiting before failing that deadline;
  it is not labeled live. Verified SCK idle samples can retain an unchanged frame.
  Summary diagnostics include captured/coalesced/dropped counts and a bounded
  failure stage, error domain and code. They do not log images, titles or input.

The previous device capture failure was **not reproduced** by local occlusion,
including on the old sender. The waiting-clock defect is a code finding, not proof
of that failure's cause. New diagnostics and the physical retest must settle it.
Similarly, the scene regression reproduces a real reopen defect, but does not
establish that every OS presentation condition from the first slot is resolved.

## Local evidence

A Mac receiver uses production `VideoSocket`, flow validation and sample framing,
then actually decodes H.264 with VideoToolbox. It measures receive/decode cadence,
format changes, encoded bytes, keyframes and pixel hashes. This is a loopback
receiver, **not** headset display rate or end-to-end interaction latency. Pixel
hash changes alone do not prove the semantic contents of a nonce or counter.

An injected 80 ms consumer/ACK delay made the old sender deliver **225 keyframes
in 226 frames / 8,815,386 video bytes** over 20 seconds. With admission before
encoding, the same geometry and delay produced **7 keyframes in 207 frames /
474,080 bytes**. About 95% fewer encoded payload bytes; decoded rates were 11.30
and 10.35 fps respectively. This diagnoses dependency/keyframe churn, not a claim
of improved throughput: concurrent Mac load was not controlled across the runs.
Sender diagnostics for the repaired run report zero encoded-frame drops.

The first repaired parallel run decoded **1,139 frames per source over 40 seconds
(~28.47 fps each)**. Native p95 receive interval was 49.6 ms (maximum 103.9 ms),
Simulator 46.5 ms (maximum 107.5 ms). The Mac source changed wide → portrait → wide
after startup and remained capturable behind its own opaque cover. Both senders
reported zero encoded-frame drops. There was no capture failure during that run.

A disposable fixture then crashed in manual CoreText/NSString drawing, after the
media run. It now uses persistent NSTextField labels. The final rehearsal with
that fixture, bounded sender summaries, build fingerprints and check results are
in [sanitized evidence](evidence/2026-11-10-native-preview-hardening/summary.json).
This is a rig fix; it must not be confused with a product capture failure.
The final fixture run decoded 1,114 Mac frames (27.85 fps) and 1,125 Simulator
frames (28.12 fps), with zero encoded drops on either sender. Both aspect changes
were decoded, the fixture stayed alive afterward, and fresh PTY ACKs and normal
preview-open/layout requests succeeded. The isolated rig was then stopped.

Required checks: lint, TypeScript, 70 companion tests, native gateway/state tests,
real socket/flow tests, hardware H.264 decode, terminal keyboard/WebKit, formatting,
harness regeneration/parity, full visionOS simulator build and signed Mac/device
builds. Packaged-app supervision/PTY replacement checks also pass. Their startup
assertion now reads a ready desktop status frame; the first frame can precede
service admission and contain the legacy log-path fallback.

The real-helper regression also opens more invalid media clients than the viewer
limit and verifies cleanup, without capture permissions. This caught an attempted
log-noise optimization that skipped the viewer removal callback; that optimization
was removed before final packaging.

## Rig fixes and staged artifacts

[Rebuild/rehearsal sources](probes/native-preview/README.md) are checked in under
`.plans/probes/native-preview`; they are isolated experiments, not a second product
window manager. All opens use the existing source resolver and revision-checked
layout API. The app owns its persisted client ID.

- Signed Mac app: `/tmp/slz-preview-validation/mac/SlopZooka.app`;
  `com.slopzooka.probe.nativepreview.mac`, display **Slz Preview Test**.
- Signed headset app: `/tmp/slz-preview-validation/vp/Build/Products/Debug-xros/SlopZooka.app`;
  `com.slopzooka.probe.nativepreview`, display **Slz Preview Test**.
- Dedicated iPhone 16e simulator: `761C24A5-F683-49C2-A87D-5899350E65D4`.
- Mac decode receiver and local private evidence: `/tmp/slz-preview-hardening/`.
- Certificate team: `6Z445J2X34`. Signatures verified; permission attribution for
  the final shipping identity remains a separate gate.

`launch` installs only the isolated headset bundle and supplies the test address
**and host ID**, preventing a saved production host identity from winning discovery.
It never supplies `-companionClientID`. After pairing, `adopt` reads the real client
ID from authenticated native diagnostic ingestion, then seeds its desired layout
through the normal API. A changed or ambiguous ID fails loudly. `restart-viewer`
launches without address, identity or method overrides, so persistence is actually
under test. Adoption/restart must still be observed on the headset.

Covering affects the disposable Mac source only, follows its resize, and is undone
on cleanup. No full-screen opaque cover. Fixtures, helper, session service, ports
and homes are isolated. Cleanup is ownership checked; installed SlopZooka and its
existing PTYs are left running. Pairing codes are read just before entry; no code
in this document should be reused. These new binaries have not been installed or
launched on the physical headset during preparation.

## Executed slot: four short wearer batches

Target **5–7 minutes after pairing**, with a charged headset. No timed shutdown.
Stop on the first failed gate and save evidence; do not spend the wearer's slot
repeatedly rebuilding or troubleshooting. No Mac lock test in this slot.

Operator starts the staged runner, waits for `sources` and Direct readiness, then
runs `launch` only when the wearer is ready. Read `code` immediately. Pair normally;
if needed, choose the advertised **Slz Preview Test** companion or use the exact
current address. After “connected,” operator runs `adopt` and verifies two original
PTYs plus the two desired previews. Expect a brief initially empty launcher while
its real layout is seeded; never solve it by injecting a client ID.

1. **Freshness, motion, shape.** Both previews show the current nonce and moving
   markers; iPhone is tall and text is readable. Give one motion verdict, including
   whether the regular stutter remains. Enlarge the Mac preview, then Reload from
   its top controls. Confirm comfortable handles and retained user scale.
2. **Close/reopen without launcher.** Close the Mac preview, then close the
   launcher only; keep iPhone and terminals visible. Operator confirms the saved
   close, covers the Mac fixture, changes nonce/counter (`pulse`), then requests
   `open`. Confirm Mac returns beside the remaining scenes, fresh and streaming,
   with no launcher repair. Operator makes portrait → wide changes and checks
   source geometry; do not count a decoder header as the visual verdict.
3. **Direct and autonomous restoration.** Use a terminal menu to open Settings;
   select Direct. Both terminals must work and native previews must explicitly
   say Direct is unsupported. Close the launcher. Operator uses `restart-viewer`
   with **no launch overrides**. Confirm the saved method and real client ID,
   correct unavailable message, and fresh ACKs in both original PTYs.
4. **Return to LAN.** Switch to Local Network once. Existing previews recover with
   fresh content and correct shapes. Confirm no extra terminals or previews.
   Wearer can remove headset; operator saves logs and stops only the test rig.

No need to repeat transport-helper recovery, broad source discovery or browser
parallelism in this slot: those already have separate evidence. Brief terminal
focus reconnect flashes remain a recorded transport UX issue. A persistent outage
or misleading Direct message is a failure, not an acceptable flash.

Passing these gates qualifies this preview slice for the next review. First-install
Screen Recording repair, integrated lock/unlock/source-loss behavior, capacity and
thermal limits remain explicit later gates. Native Direct video, MCP and the global
orchestrator remain subsequent work; this patch does not expand their scope.
