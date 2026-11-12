# Preview release deployment — 2026-11-10

Transport PR #54 and native previews PR #56 merged after both companion and visionOS CI checks passed at their final heads. Main is e37ad818516e8cffe556ce116ba0f627ce0637d9.

## Installed and verified

- Fast-forwarded the primary main checkout; built and signed both apps from that revision.
- Replaced /Applications/SlopZooka.app. Installed executable hash matches the build artifact; code signature verification passed.
- Updated the active SlopZooka Dev headset app (com.samragsdale.SlopZooka.dev) in place and relaunched it. Its data container was not uninstalled. The separate regular SlopZooka app remains installed.
- Removed ProbeViewer, SlopZooka Gateway Probe, Slz Link Probe, Slz Preview Test, and Slz Transport Test. Final device inventory contains only the two real SlopZooka apps among matching bundles.
- Companion health is successful with the original host identity and a new HTTP companion instance. The original session service PID and instance remain unchanged. All 25 session IDs survived, including all 20 running sessions.
- Native window previews are enabled for this Mac launch through SLOPZOOKA_WINDOW_PREVIEWS=1; the product default remains disabled. No permission database or user Codex configuration was changed.

## Deployment observation and limits

The first Mac launch exceeded the existing 15-second companion startup deadline before emitting companion diagnostics. A second launch succeeded. The cause is not established; do not label this a capture, networking, or signing failure without more evidence. The previous signed bundle is retained outside Applications for rollback.

These checks establish installation, launch, health and process preservation. They do not establish a fresh wearer-visible validation of the final rounded-corner cleanup, shipping-app Screen Recording permission, or every restored spatial window. Earlier device results remain in 2026-11-10-direct-native-video-results.md.

Private deployment logs and before/after inventories are under /tmp/slz-release on the test Mac. Raw credentials, session contents and device inventories are not committed.
