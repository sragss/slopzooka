# Mac → Vision direct-link results

November 10, 2026. **The direct peer-to-peer link worked and had substantially lower loaded ping latency than the LAN path in this slot.** Simply enabling peer eligibility still selected LAN. This completes the narrow [rollout step 0](2026-11-10-preview-first-rollout.md#0-quick-direct-link-check-before-product-implementation); proceed with preview implementation.

## Method and route evidence

Physical Vision Pro, visionOS 26.2 (23N301); Mac on macOS 26.5.2; Xcode 26.3. The user allowed the new viewer's Local Network prompt. The operator then drove all runs and cleanup. The same native viewer, certificate pin, bearer, TLS/TCP protocol and deterministic traffic schedule were used throughout. No screen capture or actual video was involved.

Normal runs resolved a Bonjour service and connected over IPv6 link-local endpoints with local and remote addresses scoped to `en0` in the host's established socket path. Peer-enabled discovery listed both `en0` and `awdl0`, but its actual connections—including reconnect—still used `en0`. Discovery availability is not path selection.

To isolate the direct route without interrupting the user's network, we added a small Mac-only diagnostic: look up the baseline's interface through `NWPathMonitor`, then set that specific interface in the listener's public `NWParameters.prohibitedInterfaces`. With peer mode disabled, Bonjour still discovered the service but connection/authentication timed out after 12.74 seconds. With peer mode enabled, two complete runs connected over IPv6 endpoints with local and remote addresses scoped to `awdl0` in the host's established socket path, including both reconnects. This is observed connected-path evidence, supported by the negative control—not an inference from the enable flag or available-interface list. The code does not require a hardcoded peer-interface name. [Apple interface exclusion API](https://developer.apple.com/documentation/network/nwparameters/prohibitedinterfaces).

The viewer's early `pathUpdateHandler` callbacks still showed an unresolved service endpoint (`local: unknown`) and an `en0` interface inventory. They did not independently establish the resolved device-side interface. The host's connected socket, its authenticated report, phase-end path and the exclusion/negative control establish the measured incoming route. Production diagnostics must distinguish pending service-resolution paths from established socket paths; logging an early callback is insufficient.

Both devices remained associated with their ordinary network. **We did not test physically disconnected/no-AP cold discovery**, Wi-Fi off, radio sleep/wake, roaming, distance limits or connection migration. Listener exclusion answers the narrower direct-route feasibility/performance question. It avoids the originally planned association change and restoration; the final run restores the ordinary listener configuration instead.

## Measurements

Each successful run: 2 seconds idle, 5 seconds at an 8 Mbps payload target, 5 seconds at 24 Mbps, deliberate TCP close/reconnect/authentication, then 5 seconds at 8 Mbps. Pings share that TCP connection. Cells below show **received payload Mbps / ping RTT p95 milliseconds**. Each loaded phase has about 50 ping samples; these are short sequential trials, not a statistical guarantee.

| Run                    | Actual connected route | 8 Mbps target | 24 Mbps target | Reconnect, 8 Mbps target |
| ---------------------- | ---------------------- | ------------- | -------------- | ------------------------ |
| Initial LAN, peer off  | `en0`                  | 7.50 / 160.3  | 19.79 / 161.2  | 7.15 / 167.9             |
| Same AP, peer eligible | `en0`                  | 7.92 / 165.4  | 23.94 / 157.6  | 7.38 / 206.7             |
| LAN excluded, peer on  | `awdl0`                | 7.99 / 25.4   | 23.32 / 54.5   | 7.99 / 9.6               |
| Direct repeat          | `awdl0`                | 7.98 / 13.2   | 23.15 / 79.9   | 7.99 / 17.6              |
| Final LAN, peer off    | `en0`                  | 7.92 / 171.6  | 17.24 / 186.5  | 7.47 / 147.3             |

- All five successful runs uploaded reports acknowledged by the host; all 2,135 received payload packets passed byte/order checks and matched the host's sent counts. The host skipped unsent ticks while its single bulk send was busy; lower received rates are not reported as transport corruption or maximum bandwidth.
- Direct reconnect reached the first fresh payload in 76.6 and 96.8 ms from the start of the new connection. LAN runs did so in 67.8–77.0 ms. The measured direct advantage is loaded RTT, not faster reconnect in these samples.
- Direct-path maximum inter-packet gaps were 49–168 ms across loaded phases, versus 185–206 ms on LAN. Direct delivery still had jitter; this does not establish smooth 30/60 fps rendering or a sub-100-ms worst-case guarantee.
- The 24 Mbps phase is one synthetic connection, not three captured/encoded windows. Received payload rate excludes TLS overhead. RTT is measured on one clock and includes application scheduling and TCP contention; it is not one-way latency or action-to-visible latency.

The final LAN check remained slower, supporting the observed direction of the difference. Other radio traffic, developer-device connectivity and environmental conditions were not controlled; the result must not be generalized to every access point or physical arrangement.

## Implementation decision

Keep ScreenCaptureKit → hardware H.264 → native Vision rendering and the current TLS/TCP integration candidate. This experiment is evidence for a useful **direct-link option**, not a codec or media-transport comparison.

Keep ordinary LAN as the first integration default/fallback while implementing previews. Retain peer transport as a measured optimization to expose through the existing native connection owner; neither the agent nor an MCP should manage interfaces. **An `includePeerToPeer` checkbox alone does not deliver “prefer direct.”** Any production selection policy needs explicit candidate/route handling, bounded retries and fallback, and must survive interface changes without hardcoded `en0`/`awdl0` assumptions. The diagnostic listener restriction is not yet that production policy. This is a contained networking follow-up, not a prerequisite for the preview/MCP slice or another coordinator service.

No more broad discovery is needed before implementation. Integrated rendering quality, buffering under constrained delivery, independent viewers and source/window lifecycle remain the already-planned product gates. Physically disconnected discovery can be qualified later if no-AP operation becomes a supported promise.

## Evidence and cleanup

[Sanitized measurements, endpoint scopes, source/binary hashes and raw-log hashes](evidence/2026-11-10-peer-link-live.json). Private original host/viewer JSONL, launch metadata and signed-build output are under `experiments/peer-link-probe/build/live-20261110/` and `build/live-sign.log`. The viewer was built from `e0b5830`; the Mac diagnostic added interface exclusion during the slot. The evidence records exact tested source/binary hashes. Subsequent cleanup weakens the monitor capture and rejects a missing exclusion argument; it does not change the measured workload or routing constraint.

Post-slot local checks passed again: packet/authentication checks, the four-phase TLS loopback/reconnect test, simulator build, and missing/unknown excluded-interface rejection.

The owned Mac host and headset viewer were stopped after collecting all six viewer logs (five completed runs and the expected negative-control failure). The probe app remains installed for reuse. Production SlopZooka services and terminals were untouched; network associations/settings were unchanged. The host also recorded unrelated unauthenticated loopback connection attempts, which failed TLS and are excluded from the test results.
