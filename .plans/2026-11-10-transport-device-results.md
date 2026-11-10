# Shared transport — physical Vision Pro results

November 10, 2026. The manual LAN/Direct product path worked on the headset after
one Mac listener correction. The user confirmed typing, preview gating, method
switches, and restart persistence. The historical recovery verdict and logs differ. The [local follow-up](2026-11-10-transport-recovery-followup.md) reproduced and fixed a two-window disconnect failure; a physical rerun remains the final recovery check.

## Rig and evidence

- Headset: separately signed **Slz Transport Test**, bundle
  `com.slopzooka.probe.transport`, product source `72c7f3e`.
- Mac: isolated packaged companion/home, two disposable PTYs, and a localhost web
  fixture. macOS 26.5.2; Xcode 26.3 / Swift 6.2.4; Node 22.20; pnpm 10.28.
- The normal SlopZooka apps and user session service were not restarted. No Mac
  lock, Wi-Fi change, or headset reinstall was part of the recovery checks.
- The existing layout API and gateway restored the fixture windows. No new
  product test hooks, window registry, or process owner were added.
- [Sanitized evidence](evidence/2026-11-10-transport-device.json) retains selected
  timestamps, interface/connection IDs, verdicts, final layout, and report hash.
  The private raw report is at
  `/tmp/slz-transport-acceptance-xqyM7S/diagnostics-report.private.json`;
  report ID `34b4478f-daea-4e5f-ae0b-5d8c7499eb93`, 697,492 bytes,
  SHA-256 `cb62e92a63feb262c56352dfcfebfacecfda9f75fcbbe68c22bf19d4e5764147`.
  It contains 1,022 retained events, no reported truncation/malformed records,
  and completed flushing. `mac-menu` is absent because this rig launched the
  packaged companion directly. Retained diagnostics are still best-effort evidence.

## Results

| Check | Observation and limit |
| --- | --- |
| Pairing and LAN | User connected and confirmed a terminal input ACK. Actual terminal relay traffic used `localNetwork`. The loopback address in an HTTP error was the expected headset adapter, not the destination Mac. |
| Initial Direct attempt | Discovery succeeded, but native channels timed out and no Mac peer admission appeared. Switching explicitly back to LAN restored both terminals. |
| Corrected Direct | Mac admitted `awdl0`, interface index 16, at 20:07:04.750 UTC. Two relay connections opened on `direct` at 20:07:05.511/.512. Both browser terminals recorded acceptance. User confirmed input ACK and an unavailable preview. |
| Negative control, LAN still healthy | Replaced the candidate with a freshly started original helper at 20:09:03. The original listener reported ready at 20:09:04.446, but no peer admission or terminal reconnect appeared during the approximately 51-second control interval. No silent LAN fallback was recorded. |
| Helper recovery, launcher closed | Restored the candidate at 20:09:54.879; ready at 20:09:56.042; peer admitted at 20:09:58.121. The first relay reopened at 20:09:58.132. User said “Both recovered and acknowledge typing.” **Evidence gap:** only `transport-a` has a corresponding relay/browser reattachment before the next manual switch; `transport-b` does not. The 2.09 seconds from listener-ready to first relay is one observation, not an all-window recovery SLA. |
| Rapid method changes and explicit close | User closed the unavailable preview, then selected LAN → Direct → LAN. Both terminals worked and the preview stayed closed. Final durable layout revision 2 contains exactly the two terminal records. |
| Test-app restart on Direct | Native connection accepted `direct` with `paired: true` at 20:15:22.026. Both relays and browser terminals reattached by 20:15:22.526. User's final verdict: “All correct”—Direct retained, both terminals usable, preview still closed. |
| Process preservation | Only two `session.created` events, both during preparation. Session-service instance `802f9c39-bd2c-4d97-b958-9f66ef4860c0` remained unchanged. The fixture reported the same Python PIDs (A: 71621; B: 71620) before and after the interruptions. Session creation logged parent PIDs 71608/71609; these are distinct from the fixture child PIDs. |
| Cleanup | Captured state and diagnostics, terminated only the test headset bundle, and stopped the isolated companion/session service/fixture. Confirmed its companion, helper, and fixture PIDs were gone. The test app remains installed but closed. |

## Listener correction

The original Mac listener combined:

```swift
parameters.includePeerToPeer = true
parameters.requiredInterfaceType = .wifi
parameters.prohibitedInterfaces = physicalWiFiAdapters
```

Removing only `requiredInterfaceType = .wifi` made Direct work. Restoring that
line in a fresh original helper reproduced the outage; restoring the candidate
restored admission. This distinguishes the parameter change from a lucky restart.
It establishes behavior of this configuration on these devices, not a general
claim about every Network framework listener.

The admission boundary is unchanged: dynamically discover/exclude physical Wi-Fi
adapters; require scoped IPv6 link-local endpoints on the same nonphysical Wi-Fi
interface; recheck on path changes. TLS and the admission marker still precede
forwarding product traffic. No hardcoded `awdl0` assumption was added. Bonjour
browsing behavior was not changed.

## Other findings and corrections

**Unavailable preview retries.** The captured headset build attempted Open every
session poll while Direct correctly returned HTTP 409. This produced repeated
network/window error events for expected unavailability. After the slot,
`WindowGateway` was changed to consult the existing server-authored frontend
capability before restoration. It retains the same window intent and visible
reason, and resolves when the catalog becomes available. It adds no separate
retry state or persistence. Missing capability data still allows normal resolution;
an initial Open can race catalog loading. Native regression coverage verifies
repeated polls make no Open requests, terminals recover independently, and later
availability resolves the preview exactly once. This cleanup was not device-tested.

**Pairing friction.** Early attempts targeted the previously discovered normal
companion instead of the intended test instance. Relaunching the test bundle,
then clearing the entire six-digit field and entering the current code succeeded.
The initial Local Network permission/selection timing remains a hypothesis, not a
proven cause. A follow-up should make the selected Mac/address obvious and avoid
surfacing the internal loopback origin as the apparent destination of a pairing
error. No pairing code or credential is committed with these findings.

**Fixture schema.** The temporary workspace seed omitted `isPrivate` and
`owner.avatarUrl`, causing native workspace-catalog decoding to fail. Correcting
the isolated fixture resolved it; this was not a product transport failure.

## Remaining qualification and rollout

1. The [local follow-up](2026-11-10-transport-recovery-followup.md) reproduced and fixed a relay EOF failure. Confirm that fix physically before declaring automatic recovery
   of all windows. A focused follow-up should record an independent ACK in each
   terminal, correlate each connection ID, and leave the method unchanged. The follow-up establishes the stalled-socket mechanism with real WebKit, while
   preserving this historical evidence gap. The terminal remains the sole retry
   owner.
2. Keep selection manual and Direct experimental. This pass demonstrates an
   admitted peer path while normal Wi-Fi remained available; it does not establish
   cold startup without an access point, hotel/airplane behavior, or offline first
   pairing. Those need their own controlled slot.
3. Sleep/wake, lock/room behavior, sustained load/latency, media throughput, and
   physical placement across installs remain outside this pass. The explicit
   fixture client ID on every launch does not qualify normal-app ID persistence
   across reinstalls. Video and orchestration remain later implementation stages.

The shared transport abstraction did not need another networking layer: the
listener correction is local to Mac ingress, preview gating stays in the existing
catalog/gateway, and the centralized logger supplied evidence across native,
WebView, relay, and session-service owners.

## Post-slot verification

Native state checks passed, including the new unavailable-preview regression.
TypeScript/Swift lint, typecheck, formatting, 62 companion tests, the real WebKit
keyboard suite, and the visionOS simulator build passed. Browser asset regeneration
produced no changes. The ad-hoc signed Mac app rebuilt successfully; isolated
packaging, supervision, PTY-survival, private IPC, HTTPS preview, and stalled-startup
checks passed. These checks did not restart the installed companion.
