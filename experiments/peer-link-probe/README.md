# Peer link probe

Small, disposable Network.framework experiment before the [preview rollout](../../.plans/2026-11-10-preview-first-rollout.md#0-quick-direct-link-check-before-product-implementation). Separate Mac CLI and Vision app; no SlopZooka services, terminals, screen capture or global network settings are changed. About 17 seconds of traffic per successful run, plus discovery/handshakes.

## Question and scope

Does Apple peer-to-peer Wi-Fi work usefully on this Mac/headset pair, and should v1 enable it? Compare the **same TLS/TCP protocol and synthetic payload** with `includePeerToPeer` off/on in the listener, Bonjour browser and client. Both variants use the same Bonjour service endpoint, pinned server certificate and random bearer. Only one host variant runs at a time, so this experiment's peer advertisement is absent during the baseline. Other apps can still activate peer networking; record Mac Virtual Display/AirDrop/other relevant activity.

Each run measures 2 seconds idle, 5 seconds at 8 Mbps, 5 seconds at 24 Mbps, deliberately reconnects/authenticates, then sends 8 Mbps for 5 seconds. The two loads approximate one/three encoder budgets but are **one synthetic connection**, not three independent captures or a capacity benchmark. No codec, pixels, decoding, presentation latency or compression is tested here. Keep native H.264/media qualification in the rollout.

The host sends 33,333 or 100,000 payload bytes at 30 Hz, with one bulk send outstanding and a two-second stalled-send cutoff. Small pings share that connection so RTT includes contention with bulk data. Logs include discovery/authentication time, host scheduling/skips, received payload Mbps, frame gaps, ping p50/p95/max, and time to first payload after reconnect. Payload integrity and order are checked. RTT uses only the client's monotonic clock; no cross-device clock subtraction. Goodput divides received payload by the receiver's request-to-phase-end interval, including control overhead. It is not maximum link throughput. Zero RTT samples are invalid, not zero latency.

`includePeerToPeer=true` means **eligible**, not proven direct radio. Record both endpoints, used interface types and available interfaces at both ends. `availableInterfaces` alone does not prove the chosen interface. No hardcoded `awdl0`, private API or forced interface selection is used. If the actual route cannot be established, classify it **inconclusive**; do not call it a direct-link pass. A controlled no-shared-LAN run plus a failed peer-disabled negative control supplies stronger evidence than the flag alone.

## Prepare

```sh
python3 experiments/peer-link-probe/build.py --checks
# Compile physical-device variant without installing or signing:
python3 experiments/peer-link-probe/build.py --device
# For the live slot, build signed with the selected development team:
python3 experiments/peer-link-probe/build.py --device --team TEAM_ID
```

Requires Xcode and `xcodegen`. Generated projects, logs, certificate/private key and connection configuration live under ignored, private `build/`. The viewer bundles only the random bearer and certificate fingerprint, so the operator can install it without making the user type pairing credentials. This is disposable test provisioning, not production pairing. Never publish that app/build directory. To rotate credentials, remove that experiment's build directory and rebuild both peers.

Mac host commands (run one at a time, stop the owned process with Ctrl-C):

```sh
cd experiments/peer-link-probe
build/link-probe host build/connection.json > build/same-ap-lan.jsonl
# For peer-enabled cases, after stopping the previous host:
build/link-probe host build/connection.json --peer > build/same-ap-peer.jsonl
```

Install `build/DerivedData/Build/Products/Debug-xros/PeerLinkViewer.app` with Xcode/devicectl. Open **SlopZooka Link Probe**, approve Local Network, choose the condition and matching Run button. The operator can launch it with `--autorun --condition same-ap` and add `--peer` for the peer-enabled run. Mode mismatch fails instead of silently contaminating the comparison. The bundled config must match the running host. No manual IP entry is involved.

The viewer writes JSONL to its Documents directory, including failures. Successful reports also reach the host JSONL, acknowledged before the viewer shows completion. The report contains phase results and client paths; the host log also retains its path/reconnect events. Preserve separate filenames per run, physical positions/OS versions and the observed network condition. If a run fails before report upload, retrieve the app's Documents container. Stop the owned host and close the viewer after testing.

## Short physical test

| Case                            | Host/viewer flag | Evidence                                                                               |
| ------------------------------- | ---------------- | -------------------------------------------------------------------------------------- |
| Same AP baseline                | off              | Full traffic/reconnect report and endpoints                                            |
| Same AP eligible                | on               | Same workload; classify selected route from evidence                                   |
| No shared LAN, negative control | off              | Discovery/connection fails within bounded deadline                                     |
| No shared LAN, eligible         | on               | Full report; confirm no Ethernet, tether, VPN or remaining shared LAN explains success |
| Restore ordinary LAN            | off              | Full report/reconnect after restoring original association                             |

The operator drives builds, host mode and result collection. User involvement: initial permission, one agreed association change and restoration if needed. **Keep Wi-Fi radios on.** Arrange the no-shared-LAN condition only during the test slot; don't change router settings, forget saved networks or disable radios automatically. If ordinary controls cannot safely isolate the route, record that case as untested and proceed with LAN. Discovery or connection failure itself is a result, not a reason to expand this into a networking project.

Complete this bounded comparison before product implementation, record the default decision, then proceed. A working no-AP connection may justify an optional fallback even if LAN is faster. Enable peer mode by default only if the measured benefit warrants the observed overhead; repeat a noisy/surprising case once before drawing a conclusion. No universal latency SLA or automatic live connection migration is established by this probe.

## References

- [Apple `includePeerToPeer`](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer): enables link technologies; not a preference or route assertion.
- [Apple DTS on peer networking](https://developer.apple.com/forums/thread/751839): infrastructure may be preferable, peer mode can add latency/affect infrastructure, and TCP migration needs explicit reconnection.
- [Apple networking API guidance](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api): use Network.framework for Apple peer-to-peer Wi-Fi.
- [Connection path interfaces](https://developer.apple.com/documentation/network/nwpath/availableinterfaces): keep availability distinct from observed use.

See the [test log](../../.plans/2026-11-10-peer-link-preflight.md) for actual checks and the pending physical comparison.
