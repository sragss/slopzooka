# Direct-link probe: preparation and test log

November 10, 2026. This implements [rollout step 0](2026-11-10-preview-first-rollout.md#0-quick-direct-link-check-before-product-implementation). The [isolated probe and operator instructions](../experiments/peer-link-probe/README.md) define the test. **Local preflight passed. The subsequent [physical comparison is now recorded separately](2026-11-10-peer-link-live-results.md); this section retains the preparation-time evidence.** During preflight, no network setting, production service, terminal, screen permission or headset installation was changed.

## Prepared experiment

Native Mac CLI and native Vision app use Bonjour service endpoints and authenticated TLS/TCP. The listener, browser and client all use the selected peer-eligibility setting. A fresh server pin/bearer is generated into the ignored private build directory and provisioned into the disposable viewer, removing manual IP/pairing entry during the slot. The same 17-second traffic schedule runs in either mode: idle RTT, 8 Mbps, 24 Mbps, reconnect, 8 Mbps. The viewer validates payload/order, reconciles received and sent counts, and uploads its report to the host. Failures also remain in the viewer's local log.

This is a bounded link diagnostic, not a second production networking layer. Traffic is synthetic, one TCP connection per viewer. It does not measure screen quality, three independent encoders, presentation latency, true one-way latency or maximum link capacity. Path logs retain endpoint scopes, used types and available interfaces; an enabled flag does not establish a direct radio path. Actual classification needs the physical network condition and negative control.

## Local checks

Machine: macOS 26.5.2, Xcode 26.3 (17C529), visionOS SDK 26.2. Commands and source hashes are retained in the [sanitized machine-readable evidence](evidence/2026-11-10-peer-link-preflight.json). Private detailed build/runtime logs are under `experiments/peer-link-probe/build/`.

| Check                                                                       | Result                                                                                                                                                                          |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mac CLI compile                                                             | Passed                                                                                                                                                                          |
| Fragmented/coalesced packets, invalid lengths/kinds, percentile calculation | Passed                                                                                                                                                                          |
| Wrong server certificate, wrong bearer, mismatched peer mode                | Rejected before application-ready, as expected                                                                                                                                  |
| Real local TLS traffic, all four phases                                     | Passed; 450 payload packets received and verified, sent/received counts match                                                                                                   |
| Close/reconnect, reauthenticate, fresh payload, host report acknowledgement | Passed                                                                                                                                                                          |
| Vision simulator build, both architectures                                  | Passed                                                                                                                                                                          |
| Physical visionOS build, unsigned                                           | Passed; deployment/signing and hardware run pending                                                                                                                             |
| Packaged configuration and Bonjour/local-network declarations               | Verified in the built app                                                                                                                                                       |
| Required repository checks                                                  | Passed: typecheck, 51 companion tests, native vision-state tests, terminal-keyboard tests, format, harness generation with no asset diff, full product visionOS simulator build |

Final loopback run (plumbing evidence **only**, not Wi-Fi predictions):

| Phase                    | Received payload Mbps | Frames | Ping RTT p95 ms |
| ------------------------ | --------------------- | ------ | --------------- |
| Idle                     | 0                     | 0      | 0.411           |
| 8 Mbps target            | 7.999                 | 150    | 0.358           |
| 24 Mbps target           | 23.993                | 150    | 0.344           |
| Reconnect, 8 Mbps target | 7.999                 | 150    | 0.411           |

During preparation, the initial generated Xcode project used incorrect root-file/plist paths and omitted the connection resource. Sources were grouped under `Sources`, plist routing corrected, the resource explicitly included, and subsequent simulator/device builds plus packaged-resource inspection passed. Queue ownership is explicit; the final code builds without the earlier Swift Sendable warnings. Xcode's informational App Intents metadata-extraction warning remains because this app has no App Intents dependency.

## Original physical-slot checklist (superseded by the live report)

Run same-AP baseline and peer-eligible cases, no-shared-LAN negative control and eligible case with radios still enabled, then restored LAN. Keep device positions and other active services recorded. About two minutes of automated traffic/deadlines plus setup. The operator manages mode changes, launches and evidence; the user approves initial Local Network access and any necessary association change/restoration. No automatic network reconfiguration.

| Case                         | Status   | Required conclusion                                                   |
| ---------------------------- | -------- | --------------------------------------------------------------------- |
| Same AP, peer disabled       | Untested | Baseline goodput/RTT/reconnect and route                              |
| Same AP, peer eligible       | Untested | Selected route and overhead/benefit relative to baseline              |
| No shared LAN, peer disabled | Untested | Bounded failure as negative control                                   |
| No shared LAN, peer eligible | Untested | Connectivity and route evidence excluding another LAN/VPN/tether path |
| Restore LAN                  | Untested | Baseline connectivity/reconnect restored                              |

After the slot, append observed routes/results and choose LAN default, default peer eligibility, or optional fallback. If routing remains ambiguous or direct-link performance disappoints, record that result and proceed with LAN preview implementation. Codec/media recovery qualification remains in the product rollout; this probe does not replace it.
