# Transport device acceptance — operator preparation

Completed November 10, 2026: [results, corrections, and remaining qualifications](2026-11-10-transport-device-results.md). The preparation below records the rig used.

Product revision: `72c7f3e` on `feat/centralized-transport`.
This pass tests the new LAN/Direct transport and its diagnostics, not video
streaming or the agent orchestrator. Follow the acceptance list in
[the implementation plan](2026-11-10-transport-implementation.md#before-moving-out-of-draft).

## Prepared before the device slot

- Signed physical-device build from the actual product source. Separate bundle
  `com.slopzooka.probe.transport`, display name **Slz Transport Test**; normal
  SlopZooka and earlier Gateway Probe installations are unaffected.
- Artifact: `/tmp/slz-transport-device/Build/Products/Debug-xros/SlopZooka.app`.
  Generic visionOS device build and strict signature validation passed.
- An isolated packaged companion, private home, available LAN port, native peer
  listener, two disposable PTYs, and a localhost web fixture are ready. The PTYs
  run a deterministic input/output fixture instead of launching paid model work.
- The existing revision-checked layout API is seeded with the two terminals and
  preview for this test client ID. The regular gateway restores them after pairing;
  no test-only window routing or product hooks are added.
- Terminal snapshots and input acknowledgements were checked through the real
  authenticated WebSocket. Local checks do not establish headset rendering.
- Readiness and operator results are private files in the active temporary run.
  The current run pointer is `/tmp/slz-transport-acceptance-current.json`. Do not
  print `setup.private.json`: it includes the operator's pairing bearer.
- Device install/launch waits for the user's slot. The headset was unavailable
  during preparation; this is not a test failure.

The temporary runner is `/tmp/slz-transport-acceptance-prepare.mjs`; run it in a
PTY so its command input remains open. It provides `status`, `code`, `pulse`,
`restart-helper`, `direct-off`, `direct-on`, and `stop`. Recovery commands verify
ownership before interrupting the isolated helper. Direct availability changes
restart only this test HTTP companion, retaining its test session service.
`stop` ends that isolated service and fixture. There is no overall test cutoff.

## During the slot

1. Run `launch.mjs` from the active run directory. It installs and launches only
   **Slz Transport Test**, with the test address and client ID preselected. Ask for
   Local Network approval and the fresh short-lived pairing code once. If the
   code isn't in the runner's recent buffer, obtain its latest occurrence from
   `companion.private.log`; never paste the log itself.
2. Confirm **Transport A**, **Transport B**, and the preview nonce. Have the user
   type a short disposable string, then switch Settings → Connected Mac →
   Connection method to **Direct to Mac**. Confirm terminal input/output remains
   live and the preview becomes unavailable in place.
3. Record `peer.admitted` (actual interface), HTTP/relay method attribution,
   headset connection state, and the unchanged fixture process/session IDs.
   Run isolated helper recovery. Then make Direct unavailable with LAN still
   healthy; verify there is no silent LAN fallback.
4. Restore Direct, exercise rapid toggles and an explicit preview close, then
   return to LAN. The closed preview must stay closed. Repeat recovery with the
   launcher closed and check the saved method across a test-app restart.
5. Flush the headset's queued logs by reconnecting before using the existing
   diagnostic capture API. Save the visual verdicts beside timestamps and IDs,
   then stop the isolated runner. Record remaining limitations explicitly.

User engagement is limited to first-run approval/pairing, connection-method
changes, one typing check, and short visual verdicts. The operator handles process
interruptions, status checks, artifact capture, and cleanup. The test launch uses
an explicit client ID on every invocation; this does not qualify normal-app
client-ID persistence across reinstalls or visionOS physical placement.

Cold startup without an access point, hotel/airplane networking, sleep/wake, and
media throughput remain separate qualification. Do not change the Mac's Wi-Fi or
lock the desktop as part of this narrow pass.
