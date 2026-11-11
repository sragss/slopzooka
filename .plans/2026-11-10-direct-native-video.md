# Native video on the shared Direct route

Follow-up to [the second headset slot](2026-11-10-native-preview-retest.md).
The native-video Direct restriction was a rollout gate, not a missing transport.
This change removes it. The feature remains opt-in and actual peer-link video
performance is still awaiting device validation.

## Implementation boundary

- `CompanionTransportRoute.windowChannel` already opens the fixed media upgrade
  through its selected route. LAN and Direct both have that route-owned endpoint.
- Direct already forwards opaque bytes through the pinned TLS native adapter to
  the companion's existing authenticated upgrade handler.
- Remove `assertWindowRoute` and the Direct-unavailable branch of native capture
  availability. `windowPresentation` and native source resolution no longer take
  an unused request/transport argument. They depend on capture state and identity.
- Leave authentication, TLS, peer-interface admission, route retirement, capture,
  H.264, ACK/credit limits, renderer and window persistence unchanged. No new port
  protocol, transport class, tunnel, codec path or native UI routing branch.
- Web previews retain their separate Direct restriction. Older companions may
  still return native-video unavailability; the Swift client continues to honor
  their advertised state rather than guessing support.

The only production changes are in the companion's native preview availability
and its two call sites. Tests cover the same provider's binary upgrade and recovery
through LAN and the real peer ingress. Existing native route integration now sends
350 KB of byte-exact data through the video upgrade over LAN and pinned TLS/Direct,
keeps that channel alongside real WebKit/PTY traffic, and checks that route
retirement closes it without ending terminal processes. This local TLS fixture
qualifies framing/ownership, **not** AWDL throughput or radio conditions.

Initial full-suite runs stalled in the disposable provider fixture. Its ticket
parser incorrectly assumed the ticket and payload arrive in separate TCP chunks.
The fixture now splits at the first newline and echoes any trailing binary bytes;
large-buffer assertions report length/byte equality without constructing an
expensive textual diff. Test HTTP listeners also answer unrelated discovery probes
and close ordinary connections during cleanup. Both provider routes subsequently
passed together in the full suite. No production transport change was needed.

The packaged-app check also used an early startup status for the session log path,
even after waiting for a ready status. It now uses the ready status consistently;
the signed bundle/supervision/PTY-survival check passes. An unrelated service-crash
cleanup reported ENOTEMPTY in one suite run; the final complete suite outcome is
recorded separately in the evidence summary.

## Prepared artifacts and verification

Both isolated signed apps, the fixtures and native decode probe are rebuilt through
`.plans/probes/native-preview/prepare.mjs`. It stages only; no headset install or
launch has occurred for this change. Mac:
`/tmp/slz-preview-validation/mac/SlopZooka.app`; headset:
`/tmp/slz-preview-validation/vp/Build/Products/Debug-xros/SlopZooka.app`.
The headset binary includes the archived-session discard correction from the prior
slot. Saved private test logs are under `/tmp/slz-direct-video`; artifact hashes and
final verification are in [the evidence summary](evidence/2026-11-10-direct-native-video.json).

## Combined headset slot: approximately 3–5 minutes after pairing

Use the existing isolated runner, fresh host address/code and the headset's real
persisted client ID (`adopt` after pairing). Keep the installed SlopZooka session
separate. No test-specific client-ID override or hidden cross-route fallback.

1. **Establish and reopen.** In LAN, confirm Mac + iPhone previews are fresh. Close
   only the Mac preview and launcher, keeping iPhone/terminals open. Operator
   verifies the saved close, remotely reopens the same source, and waits for the
   new scene/stream. This establishes the old-scene/replacement sequence.
2. **Two streams on Direct.** Open Settings from a test terminal and select Direct.
   Close the launcher. Operator changes the fixture nonce/counter. Confirm **both
   previews stay fresh and moving**; report motion/readability. Type `direct-check`
   + Return in Preview Test A while both stream. Operator must see the matching
   receipt from its original PTY, not infer success from an old ACK or a control
   API write. Check logged peer admission, not just the setting's label.
3. **Restart while on Direct.** Operator uses `restart-viewer` with no launch
   overrides, then changes the nonce again. Confirm both previews return fresh
   without reopening them. Verify stable client/service IDs, all four desired
   window records, native discard diagnostics, and no new PTYs. Do not repair
   layout or inject open intent after restart to manufacture a pass.
4. **Return to LAN.** Switch back once. Both previews recover fresh; terminal
   input remains usable. Wearer is finished. Operator saves summaries, closes
   only the verified test app and owned rig, and checks original apps survive.

Stop on the first failed gate and retain the evidence. No Mac lock, permission
reset, broad source-discovery exercise, or repeated geometry test in this slot.
If Direct video fails, determine whether it is upgrade/authentication, capture,
ACK/backpressure, rendering or peer-link behavior from the central logs before
changing architecture. Rounded-corner treatment and the stutter shared with the
regular Mac↔VP display remain separately recorded UX follow-ups.
