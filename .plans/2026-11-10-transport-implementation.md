# First implementation: shared companion transport

Initial base: `origin/main` at `c5b8cad` (linting and complete Swift concurrency checks). The research branch was separately merged with this revision without conflicts. Product changes live on `feat/centralized-transport`, without the research harness binaries or experiments. Research history remains in [draft PR 39](https://github.com/sragss/slopzooka/pull/39).

## Implemented boundary

`CompanionClient` retains discovery, pairing, accepted identity, method preferences, request generations, and refresh ownership. `CompanionTransportRoute` owns an ephemeral loopback origin, its URLSession, and its native byte channels. With current companions, both native control requests and the terminal document/assets/WebSocket use that origin. Companions without transport v1 retain the existing LAN origin, because their preview certificates derive from the HTTP Host header; their native URLSession is still route-owned. There is one existing xterm attach/replay/reconnect implementation; this PR does not add a JS/native terminal message protocol.

```text
Headset native API / terminal WebView
    → route-owned loopback adapter (independent TCP streams)
    → Local Network: Mac's existing HTTP listener
      Direct: peer-aware TLS 1.3 listener → private Node HTTP ingress
    → existing auth / domain APIs / session-service relay
```

The loopback adapter has one fixed destination and no endpoint-selection API exposed to web pages. Its credential binding lives in memory and is revoked on retirement. Each direction has one receive/send in flight, bounded to 64 KiB; 64 channels per listener. Route retirement cancels its URLSession, listener, and accepted channels. Uncertain input is never replayed by this layer. Native video remains a later change; no media is being put through JSON or xterm.

The Mac helper has no workspace, session, window, or HTTP domain implementation. Node starts/stops it using a private stdin lifeline, restarts it with bounded backoff, and owns both advertisements. Its private backend listener runs the existing Express handlers and session-service upgrade handler. Transport facts come from the accepting listener, not a client-provided header. A failure of the optional helper leaves Local Network available.

## Manual method and trust

- Settings → Connected Mac → Connection method: **Local Network** by default; **Direct to Mac (Experimental)** as explicit opt-in. No Auto mode or silent cross-method fallback. Retry stays on the selected method; a failed paired-Mac preference survives restart. Another paired Mac retains its own preference on this headset.
- Switching retires old documents and requests before establishing the new route. Native scenes, Mac PTYs, and desired layouts remain. Late health, catalog, or preview replies cannot reactivate old content. Returning to a supported route resolves existing windows again; closed windows stay closed.
- Initial pairing still requires a trusted Local Network. An authenticated health response provides the Mac's transport CA, stored by host ID in Keychain. Direct verifies its TLS chain, fixed certificate name, and expiry before forwarding any HTTP credentials. This reuses pairing trust rather than introducing a second enrollment system. Offline first enrollment is explicitly out of this PR.
- The transport identity has its own private CA directory. The leaf renews before expiry through the same helper recovery path; its public CA remains stable. No system trust-store installation. Memory-only identity import requires macOS 15+; Local Network remains available on the companion's older supported systems.
- `includePeerToPeer` alone is not sufficient evidence of a direct link. The Mac discovers physical Wi-Fi adapters with CoreWLAN, excludes them from its Wi-Fi-only listener, and checks each accepted socket's actual scoped IPv6 link-local endpoints against the current physical-adapter set. There are no hardcoded `en0`/`awdl0` names. The authenticated listener sends a versioned admission marker only after that check; the client does not forward product traffic before receiving it. Path changes recheck admission.
- Bonjour browsing is bounded and stops before connecting. Unknown versions, absent trust, failed authentication, and an unavailable peer route fail Direct rather than trying LAN or a different Mac.

## Preview availability

The Mac's `webPresentation` resolver is shared by catalog results and open enforcement. Direct currently reports `presentation_unsupported_on_route`, a displayable reason, and no invented alternatives. Rejection happens before allocating a frontend gateway. Local Network preserves existing web previews, including legacy companions that omit the optional availability field. A frontend's existing `transport: "direct"` describes a URL presentation and is unrelated to Direct to Mac.

The headset keeps unavailable rows visible and disables Open while retaining Remove URL. Retiring a preview removes its WKWebView and navigates its old document to blank, ending its scripts/sockets; merely calling `stopLoading` would not do that. WindowGateway remains the sole window lifecycle owner. No new window persistence schema or second window registry.

## Test log — 2026-11-10

Environment: macOS 26.5.2, Xcode 26.3 / Swift 6.2.4, Node 22.20, pnpm 10.28. Isolated temporary homes and PTYs only. The user's running companion/session service was not restarted.

| Check | Result / limit |
| --- | --- |
| Existing companion suite plus native transport integration | 51 tests passed. Ordinary suite subprocesses use `SLOPZOOKA_DIRECT=0` to avoid creating unrelated peer advertisements; native transport integration still runs real sockets/TLS. |
| Native HTTP/assets/WebSocket/PTY integration | Both plain LAN forwarding and TLS/admission forwarding carried authenticated terminal assets and Unicode/control bytes to a real PTY. Retiring/replacing the route disconnected the viewer and reattached the same running session; no duplicate process. |
| Trust rejection | A different CA failed TLS before the protected HTTP request reached the backend. The production client also connected twice to both legacy and current fixture companions: legacy retained its LAN origin; v1 used the native adapter; replacing the same legacy origin preserved the new credential/session. |
| Availability | The accepting ingress determines presentation support; spoofing a route header does not alter it. Remote/direct-URL frontends are also disabled on peer routes. |
| Native state checks | Manual choice, failure/restart persistence, backoff/no fallback, rapid-toggle late replies, window document retirement, late preview reply after close, and existing recovery/layout/process checks passed. |
| Real WebKit keyboard suite | Existing hardware/software keyboard, control/Unicode input, focus/zoom/resize, and browser-history checks passed. This does not replace running the new loopback terminal document on the headset. |
| visionOS simulator build | Passed with complete concurrency checking and warnings as errors. |
| Mac app build / packaged tests | Ad-hoc signed isolated app built; packaged supervision, PTY survival, private IPC, HTTPS preview, and timeout checks passed. |
| Native Mac ingress smoke | Production helper started with dynamically discovered interface exclusions; reported `direct: true` and a transport CA; stopped cleanly. Terminating only this isolated helper also recovered a new helper with the same CA. This establishes listener setup, not a headset data path. |

A broad test run initially exposed an assertion counting unrelated frontend-discovery probes against a fixture. The assertion now counts only the protected test endpoint. TLS rejection itself was not bypassed. CI explicitly selects Xcode 26.3 because the shared queue-confined types opt out of the headset target's default main-actor isolation using Swift 6.2 syntax.

## Before moving out of draft

One short physical-device pass, on an isolated companion home:

1. Pair over Local Network. Open two existing terminals and a web preview. Verify typing/output through the new adapter.
2. Select Direct. Confirm the same PTYs survive, both terminals attach once, the preview becomes unavailable in its existing scene, and its Open action/API both reject with the same reason.
3. While Direct is selected, interrupt only the test helper. Verify recovery on Direct. Make Direct unavailable while LAN remains healthy; verify it stays unavailable until an explicit switch.
4. Toggle rapidly, close the unavailable preview, return to Local Network, and verify it stays closed. Repeat from a recovered terminal with the launcher closed. Check a method preference across app restart.
5. Record Mac admission scopes and headset connection status together. Compare typing and sustained terminal output with the previous LAN baseline.

Cold startup without an access point, hotel/airplane behavior, sleep/wake, and media throughput remain additional qualification before promising travel reliability. Earlier peer-link experiments establish feasibility, not acceptance of this product adapter. Automatic method selection, offline first pairing, native previews, preview MCP, and Pi orchestration remain later PRs.

## References

- [Apple: choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) — Network framework for native peer-aware connections.
- [Apple: moving from Multipeer Connectivity](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework) — bounded discovery, stopping browsing before connecting, and TLS guidance. We use certificate-authenticated TLS 1.3 rather than TLS-PSK's older API/version constraints.
- [Apple: prohibited interfaces](https://developer.apple.com/documentation/network/nwparameters/prohibitedinterfaces) — interface exclusion is public API; socket admission remains separately checked.
- [GitHub macOS 15 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md#xcode) — Xcode 26.3 is available; the runner's default Xcode is older.

## Diagnostics integration — upstream PR #50

Merged `cc801a6` into the transport branch. The integration preserves one Node
diagnostics runtime per process and the shared native `AppLog`/outbox. The helper
has no separate log store. Its bounded, versioned stdout protocol carries only
ready messages and closed-schema stream metadata into the companion logger.

Native API calls, pairing, and diagnostic uploads now send through the explicit
route object. The origin registry only supplies first-party WebView credentials;
it no longer chooses a URLSession. Retired routes reject new sends. Uploads stay
outside request tracing, retain failed batches, and use the same authentication
and connection as control traffic.

Evidence available for the live pass: method changes, action IDs, host IDs,
route revisions, connection IDs, helper instance/PID and recovery delays,
TLS/network error domains and codes, the first admitted peer interface, admission/path failures, and listener
retirement counts. Both HTTP and WebSocket upgrade logs identify their real
accepting ingress. No raw terminal bytes, credentials, certificates, or helper
stderr are copied into these events. One failure sample per finite stream stage
per listener bounds diagnostics recursion and repeated connection noise.

A wrong-CA test exposed connections waiting below the HTTP timeout without
reporting their underlying TLS failure. Waiting byte channels now fail promptly
to their existing API/WebSocket owner. That owner retains retry/replay policy;
the transport does not retry uncertain writes.

Validation results and the remaining device acceptance are recorded below.

| Integration check | Result / limit |
| --- | --- |
| Companion suite after merge | 62 tests passed; real native LAN/TLS HTTP, WebSocket, and isolated PTY checks included. |
| Diagnostics over native routes | Failed authenticated uploads retained event identities and retried; idle delivery did not generate recursive HTTP events; credentials were absent from uploaded evidence. Tested legacy and transport-v1 LAN adapters. |
| Failure sampling / helper framing | Wrong-CA attempts never reached the backend and emitted one failure sample per stage/route. Split/coalesced helper frames decoded; oversized, malformed, unknown-version/event/field frames rejected without echoing bytes. |
| Accepting-route attribution | HTTP and WebSocket upgrades reported their accepting listener despite spoofed transport headers. |
| Route retirement | Retired route rejected sends; terminal process survived; native state tests retained late-reply, host-isolation, restoration, and explicit-close guarantees. |
| Static / native verification | Typecheck, TypeScript/Swift lint, formatting, native state, terminal keyboard, regenerated asset parity, and visionOS simulator build passed. |
| Packaged Mac app | Ad-hoc signed build and isolated packaging/supervision/PTY-survival/HTTPS-preview checks passed. |
| Production helper recovery | Killed only the isolated test helper. A new helper recovered with the same CA. Central log contained start, ready, unexpected exit, retry, new helper ID, and expected shutdown/retirement events. This proves listener lifecycle, not a headset data path. |

Live debugging: retain the incident timestamp; reconnect the headset before
capturing so its queued events can reach the Mac. Use the existing diagnostics
capture API and report collection, not a transport-specific exporter. Correlate
host/action/connection IDs and route revisions; `peer.admitted` records the first
validated scoped link-local Wi-Fi interface per helper lifetime. The physical
acceptance list above is still pending. No installed app or user session service
was restarted for these checks.
