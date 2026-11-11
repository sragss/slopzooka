# Transport recovery follow-up

The [physical pass](2026-11-10-transport-device-results.md) had a mismatch: the
user confirmed two recovered terminals, but only one reattachment appeared before
the next manual method change. Local follow-up reproduced a concrete failure in
the shared byte relay and fixed it without adding another retry owner.

## Reproduction and correction

`StreamPipe` forwarded `isComplete` using Network framework's default message
context. Completing that context does not close the TCP write direction. A
WebSocket could therefore retain its apparent connection after the remote endpoint
closed. Apple documents the distinction in
[`NWConnection.send`](https://developer.apple.com/documentation/network/nwconnection/send%28content%3Acontentcontext%3Aiscomplete%3Acompletion%3A%29-5ecuz).

The first regression used an HTTP response whose end is signaled by connection
closure. The original implementation delivered bytes but did not deliver EOF,
and timed out. Adding a final context fixed plain TCP. Further tests showed that
TLS write-half-close alone could still leave the peer alive, including an old
PTY viewer after its WebView closed. Forwarding response EOF alone fixed reconnect
but did not clean up those client departures.

The final contract is explicit: these fixed-destination HTTP/WebSocket channels
treat EOF from either endpoint as a disconnect. Forward any final bytes with the
final context, then cancel both native connections after send completion. This
also removes the old two-direction EOF counter. The adapter is not a general TCP
tunnel that promises independent half-close semantics. A probe that waited for
request-side TLS half-close before sending its response did not work; that
behavior is outside the control/terminal clients' contract and is not being
papered over with a timeout or another framing protocol.

No changes to terminal retries, replay, input delivery, authentication, window
identity, or session ownership were needed. The existing `TerminalConnection`
observes disconnect and reattaches. TLS authentication and interface admission
are unchanged.

## Regression coverage and evidence

The existing native transport integration test now runs two independent real
macOS WKWebViews with the production terminal HTML/JavaScript, real WebSockets,
and two isolated PTYs. A disposable Swift driver observes frames and sends input
through the existing textarea handler; it does not replace sockets or implement
reconnection. The views stay alive throughout the interruption.

| Check | Result |
| --- | --- |
| Original implementation, EOF response | Timed out waiting for EOF after receiving response bytes. Private log: `/tmp/slz-eof-before.log`. |
| Original implementation, isolated TLS two-WebView control | Both views loaded and independently acknowledged input. Ending the two remote sockets without WebSocket Close frames produced no reattachment within the 8-second assertion window. Private log: `/tmp/slz-eof-webkit-negative-control.log`. The raw HTTP check and other modes were excluded only for this temporary negative control; source was restored afterward. |
| Corrected implementation, LAN and TLS | Both views automatically reattached exactly once on the same route and independently sent fresh input, received its PTY output, and acknowledged that output after rendering. No native document reload or new process. |
| Departing views | Both backend WebSocket peers disappeared after the test views exited, so stale viewers cannot retain writer ownership in the subsequent attachment check. |
| Final response delivery | More than 400 KiB crossed multiple native buffers; every response byte and EOF arrived. This checks final-data preservation, not a throughput benchmark. |
| Existing integration checks | Route retirement/replacement retained running sessions; authentication and wrong-CA rejection still passed. |

The final focused run passed in 8.39 seconds total, including native compilation,
LAN/TLS cases, WebKit interactions, and wrong-CA checks. This is test duration, not
an interaction-latency or recovery SLA. Log: `/tmp/slz-eof-fixed-final.log`.

The test driver lives only in `apps/vision-client/tests/TransportWebKitChecks.swift`
and is compiled by `companion-transport.test.ts`. It creates disposable windows
without activating the app or taking keyboard focus. It never connects to the
installed companion or the user's sessions.

## Conclusion and remaining gate

There is now a failing-before/passing-after regression for a real two-window
recovery failure. This explains a mechanism consistent with the headset symptom;
the old trace did not record individual native EOFs, so it cannot prove that this
was the sole cause of that historical observation.

Keep Direct experimental and the PR draft until one short physical rerun verifies
independent ACKs in both terminals after a helper interruption, with the launcher
closed and no method toggle. Existing travel, sleep/wake, and media qualification
limits remain. No further headset interaction was requested during this follow-up.

## Integrated verification

Merged upstream through `1766abb` (bug-report PRs #51/#52). The only textual
conflict was in the headset guide; both transport diagnostics and bug-report
instructions were retained. New native report requests use the existing shared
route through `CompanionClient.request`.

All checks passed on the merged branch: 68 companion tests (including both real
WebKit recovery cases), TypeScript/Swift lint, typecheck, formatting, native state
checks, real WebKit keyboard checks, browser asset parity, visionOS simulator
build, ad-hoc signed Mac packaging, and isolated packaged-app tests. Logs are
`/tmp/slz-recovery-{companion,static,state,keyboard,simulator,packaging}.log`.
No installed companion, user PTY, or physical headset app was restarted for this
follow-up.
