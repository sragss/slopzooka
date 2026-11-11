# Direct native video and restoration: physical validation

**Passed the combined gate** on local 2026-11-10 (approximately 03:04–03:12 UTC
on 2026-11-11), candidate `7cd683e`, isolated Slz Preview Test. This executes the
[prepared script](2026-11-10-direct-native-video.md). The original SlopZooka Dev
headset app, installed Mac companion and original terminal service remained running.

| Gate | Evidence |
| --- | --- |
| LAN baseline | Wearer confirmed both previews fresh with nonce `4090f837`, moving markers and Mac Count 2. |
| Close and remote reopen | The first reported close did not remove the current Mac record. An operator reopen request at that point was a no-op, still revision 2. Repeating **Close Preview** through the current Mac preview's top menu persisted revision 3 with only iPhone and two terminals. Operator then reopened that same source through the normal API/layout path; revision 4 again contained four windows. |
| Direct with two video streams | Wearer confirmed both streaming. Transport logged peer admission on **awdl0** at 03:09:22; Direct Open replies and both terminal connections followed. |
| Real input alongside video | Wearer sent `direct-check`; the receipt file independently recorded it from **both original PTYs**, PIDs 37607 and 37605. This is distinct from operator-generated fixture pulses. |
| No-override app restart | Only the isolated test app restarted. It retained Direct and the same client ID, then both previews showed fresh nonce `5810ab53` / Mac Count 5. No post-restart open request or layout repair was issued. |
| Delayed-discard correction | At 03:09:56 UIKit reported 2 discarded sessions and 6 survivors, 5 archived. The gateway logged `scene.discard.superseded` for the current Mac source. Revision **4** and all four records survived. This directly exercises the fix for the prior slot's failure. |
| LAN return | Wearer: “Both worked! Very cool.” Both previews continued moving after switching back to Local Network. Original session-service identity and both terminal sessions remained unchanged. |

The wearer’s final reply covers both Direct restoration and LAN return. No further
headset action is needed for this gate. The test app (verified bundle/container,
PID 627), owned fixture processes and dedicated simulator were stopped afterward.
The original headset app PID 473 and Mac PIDs 13544/13547/32460 were preserved.

## Streaming observations and limits

Nine completed nonempty sender summaries contain **15,601 offered frames and zero
encoded-frame drops**. The four summaries whose lifetimes fall inside the Direct
phase offered 26.41–28.49 fps. These are sender counts, not physical display FPS,
end-to-end latency, or a controlled comparison with LAN. Raw video was not saved.

A diagnostics attribution issue surfaced: the capture child's callback retains
its initial request's logging context, so `stream.summary.connectionMethod` keeps
saying `localNetwork`, including during Direct. Do not use that field to classify
media routes. The route selection events, awdl0 peer admission, Direct requests,
stream lifetimes and wearer observation establish this run's Direct phase.
Follow-up: give provider lifecycle logs neutral process context and bind viewer
route metadata explicitly through the existing logger; do not create a new logger
or transport boundary. Empty discovery-probe connections also generate zero-frame
summaries and should not be counted as failed video sessions.

This qualifies nearby peer-link native video, manual input, app restart and route
switching in this setup. It does not establish travel without an access point,
sleep/wake, long-duration thermals, eight-viewer capacity, measured interaction
latency, or lock/source-loss behavior. Existing rounded-corner and rhythmic-stutter
observations remain separate UX follow-ups.

## Front-ends warning reported by the wearer

The wearer saw Direct-unavailable warnings on the launcher's Front-ends tab.
Source inspection finds two separate sections:

- Web rows use `webPresentation`, which still intentionally disallows URL-based
  previews on Direct. They display “Web previews are not supported on Direct to
  Mac yet. Choose Local Network in Settings.”
- **Mac windows** uses native capture availability, which no longer has any Direct
  restriction. Both native streams worked in this slot.

There is no remaining global native-preview switch to flip. A browser shared as a
Mac window can stream on Direct; opening its URL as an embedded web preview remains
a different path. Record a clarity improvement: label the web section explicitly
and make this distinction visible near its restriction. We did not independently
observe a native row showing the warning, so do not claim that report was disproved
or silently enable unsupported web routes. No product code changed during this slot.

[Sanitized events, receipts, summaries and cleanup evidence](evidence/2026-11-10-direct-native-video-results.json).
Private logs remain in `/tmp/slz-preview-validation/run-jf6Kzy`.
