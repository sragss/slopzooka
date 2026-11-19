# Choosing the headset for a preview

## What happened in woo-demo

On November 18, a saved Codex thread resumed from Ask in the test app. Its two preview_list calls at 18:46 and 18:55 EST both returned the regular Mac companion and the regular headset client ID. A concurrent readiness check against the two configured pairings later returned false on port 7777 and true on the test companion on port 55436. The worker accurately reported the answer for a different pairing.

Coordinated workers already receive a private preview configuration when Ask starts them. A resumed local Codex thread uses the laptop-wide MCP installation. The host already supplies SLOPZOOKA_SESSION_ID to PTYs, and the installed MCP forwards it. This is enough to identify an originating terminal when the companion records its destination at launch. Readiness belongs to a specific companion and headset app client. Several clients can be installed on the same physical headset.

## Decision

Keep one installed preview MCP and give each preview one destination. The destination is a trusted companion and a headset app client. The Mac owns this choice. A normal user with one pairing never sees a picker. A developer can have production and test running throughout the day and use the same MCP installation.

| Option | Effect in the woo-demo case | Recommendation |
| --- | --- | --- |
| One running instance on both devices | Switching to the test rig still leaves the installed MCP pointing at the regular pairing. Enforcing exclusivity on the Mac also complicates development alongside live terminals. | Keep the existing session-service lock per SlopZooka home. Allow separate homes to coexist. |
| One receiving app on the Vision Pro | Reduces ambiguous choices for laptop requests. It still takes a Mac-side resolver to find that app, and the active app may belong to a different session. | Consider an explicit “Use this app for laptop previews” preference only if ambiguity is frequent in practice. |
| Write to both | Each app has its own saved layout. An open can succeed twice, or a close can succeed on only one. A test can also change the user’s regular layout. | Probe multiple trusted destinations when necessary. Send each change to exactly one. |
| Bind to the session that asked | A thread resumed from Ask in the test rig opens on that rig even with both apps ready. | Ship this first. |

Focus changes are common during headset use. SwiftUI exposes the operational state of a scene and an aggregate across an app’s scenes. Neither identifies which SlopZooka client launched a particular terminal. [Apple’s ScenePhase documentation](https://developer.apple.com/documentation/swiftui/scenephase)

## What the user experiences

| Request | Behavior |
| --- | --- |
| “Show this on my headset” inside a SlopZooka terminal | Open on the companion and client that launched this terminal. The same rule covers Ask workers, new Codex sessions, and resumed threads. Attaching a second viewer keeps the original destination. |
| Same request from ordinary laptop Codex | Check trusted pairings on demand. With one ready destination, use it. With two, ask once in conversation, e.g. “Open it in SlopZooka or SlopZooka Test?” Reuse the choice for follow-ups in this session. An explicit destination takes precedence over automatic selection. |
| “Rename that preview” after another app connects | Rename the existing preview in its original layout. Newly created previews may target another app when explicitly requested. |
| A chosen destination stops answering | Say “SlopZooka Test is not available right now.” The user can retry or explicitly choose another destination. Distinguish a stale pairing and a Mac capture-permission problem in the actionable detail. Ordinary laptop coding performs no probes. |

## Implementation sequence

1. **Carry the origin through launch and resume.** Generalize the private route already provided to Ask workers. At authenticated headset launch, bind the companion identity and client ID to the Mac session ID. Pass its private configuration reference to the installed MCP through the terminal launch environment. Resolve it before the laptop default. Keep the binding with the retained session across companion restarts and changes between LAN and Direct. Scope it to the terminal lifetime so a later, fresh resume of the same historical thread can belong to another client. A pre-existing terminal without a provable origin follows laptop selection on its first explicit preview request.
2. **Keep follow-ups on the same route.** Preserve the four existing tools. Bind source and preview handles returned by the MCP to the selected pairing, leaving persisted scene and source IDs alone. Two clients on the same host can legitimately have the same raw preview ID. Reject mismatched or expired handles and offer a fresh list. Reuse host verification, the fresh per-client presentation probe before every write and conflict retry, and the existing revision-checked layout store. A saved layout acknowledges requested state. If a reply is lost, read that same layout before retrying. WindowGateway continues to own presentation. Log the session, host, client, selection reason and outcome, excluding credentials. [Preview MCP](https://github.com/sragss/slopzooka/blob/807b723/apps/mac-companion/src/preview-mcp.ts) · [Mutation and acknowledgement](https://github.com/sragss/slopzooka/blob/807b723/apps/mac-companion/src/preview-control.ts) · [Layout and availability](https://github.com/sragss/slopzooka/blob/807b723/apps/mac-companion/src/window-layout.ts)
3. **Add laptop selection.** Seed a user-private Mac inventory from the current installed pairing. Let additional paired companions register a reference to their private configuration. Key entries by host and client; treat ports as changeable addresses and verify host identity on contact. Use bounded parallel readiness checks only for unbound requests. Give candidates distinguishable display names and allow an optional destination on the existing list tool to answer the disambiguation. Remember the choice within the requesting session. A revoked credential or identity mismatch needs repair before that entry can be selected. The common path needs no new settings, always-on router, or headset protocol.

## First PR and device check

The first PR covers headset-launched Codex terminals, saved-thread resume, and pairing-specific MCP handles. The launcher supplies the route when it starts Codex, using the same command-line override as an Ask worker. The paired HTTP companion publishes a private configuration file. A shared session service keeps the running process and its original launch arguments when a second client attaches. The laptop picker remains a later change. An older session service reports the required update on a routed launch. Schedule that restart around the user's existing terminals.

For the device slot, run the staged companion with an isolated home and session service. Keep the regular and test apps connected. Open a saved thread from Ask in test and request a fixture preview. With the launcher closed, rename it on Direct, then close it after switching back to LAN. Check both client layout revisions against the baseline captured immediately before each preview action. Production should receive zero preview changes. Take the test client offline with production still available and repeat the request from the same terminal. It should name the availability problem and leave production untouched. No device result has been recorded for this change yet.

## Release gate

| Test | Passing evidence |
| --- | --- |
| Replay woo-demo with the regular pairing offline, then with both ready | A fresh terminal, resumed Codex thread and Ask worker from test each open exactly one preview in the test layout. Regular layout revision stays unchanged. |
| Two terminals on different pairings request the same Mac source concurrently | Open, rename and close stay on their original client even when raw IDs coincide. Retry after a lost response produces one desired window. |
| Laptop with zero, one or two ready pairings | Zero returns unavailable. One opens directly. Two produce a named choice and no write before selection. A follow-up reuses that choice even if readiness changes. The existing single-pair installation works without reinstalling the MCP. |
| Disconnect between list and open, restart the HTTP companion, or reuse its port for another host | No write reaches the other pairing. A saved request is distinguishable from a visibly rendered window. The retained terminal keeps its binding. |
| Short real-headset pass with production and test both open | Resume from test, show a preview, close the launcher, switch between Direct and LAN, then rename and close from the same terminal. Verify the visible header and both saved layouts. |

Ship session binding and handle isolation first. The remaining product question is how often ordinary laptop users actually have two ready destinations and want to change the choice. Measure that at selection time before adding a persistent default or coordinating a receiver role across headset apps.
