# Architecture

[Back to README](../README.md) · [Development](../CONTRIBUTING.md)

The Mac owns workspaces and terminal processes. The headset owns native presentation and input. The HTTP companion connects them; a separate local session service keeps terminals alive when the companion restarts.

## Repository map

| Path                                                | Responsibility                                                                  |
| --------------------------------------------------- | ------------------------------------------------------------------------------- |
| [apps/shared](../apps/shared) | Native diagnostics runtime and Mac file sink shared by both apps |
| [apps/mac-menu](../apps/mac-menu)                   | SwiftUI menu-bar app, companion supervision, pairing display, and login startup |
| [apps/mac-companion/src](../apps/mac-companion/src) | HTTP companion, session service, workspace management, and browser UI           |
| [apps/vision-client](../apps/vision-client)         | Native visionOS launcher, windows, WebViews, and speech input                   |
| [packages/protocol](../packages/protocol)           | Terminal messages, runtime validators, and the shared window-layout fixture     |
| [scripts](../scripts)                               | App packaging and native regression checks                                      |

## Mac ownership

Paths below are relative to `apps/mac-companion/src`.

| File                                     | Responsibility                                                                                                                    |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `server.ts`                              | HTTP routes, authenticated WebSocket transport, discovery, and shutdown                                                           |
| `logger.ts` / `log-events.ts`             | Process diagnostics composition and portable scoped logging; component loggers have no storage API |
| `log-store.ts` / `diagnostics-http.ts`    | Per-process log rings, raw incident capture/export, and paired-client batch intake; future report tooling owns time filtering |
| `companion-transport.ts` / `transport-helper.ts` | Native ingress lifetime and bounded helper IPC; observations enter the process logger |
| `bonjour.ts`                             | Service registration through macOS DNS-SD; macOS owns hostname/address records, and a private pipe bounds registration to the HTTP companion lifetime |
| `sessions.ts`                            | `SessionManager`: PTYs, screen state, replay, resize ownership, and input deduplication; instantiated only by the session service |
| `session-service.ts`                     | Private service entry point, terminal dispatch, shutdown, and lock-protected socket/runtime cleanup                               |
| `session-service-client.ts`              | Connect-or-start, retained runtime installation, HTTP control, and bounded viewer relay; no session registry                      |
| `session-service-protocol.ts`            | Versioned local control contract                                                                                                  |
| `window-layout.ts`                       | Client-scoped desired window layouts, atomic persistence, and revision checking                                                   |
| `workspace.ts`                           | Git worktrees and workspace persistence                                                                                           |
| `bug-report.ts` / `bug-report-draft.ts` / `bug-report-http.ts` | Browser composition, explicit public draft projection, and bounded native review/submission; captures stay local |
| `github.ts`                              | Repository discovery/creation and fixed-destination bug issue submission through host credentials                                                                                  |
| `dashboard-address.ts`                   | Optional Portless dashboard alias, verified redirects, and localhost fallback                                                     |
| `frontend-discovery.ts`                  | Read-only Portless adapter, listener inventory, and bounded HTTP probes                                                           |
| `frontends.ts`                           | Unified frontend catalog, saved URLs, and preview gateways                                                                        |
| `project-frontends.ts`                   | Workspace frontend configuration and ownership matching                                                                           |
| `harness.ts`                             | Browser dashboard                                                                                                                 |
| `terminal.ts` / `terminal-connection.ts` | Browser terminal renderer, reconnect, and ordered rendering                                                                       |

[`scripts/build-mac-app.mjs`](../scripts/build-mac-app.mjs) packages the signed Mac app. [`build-session-runtime.mjs`](../apps/mac-companion/scripts/build-session-runtime.mjs) builds the retained terminal runtime using existing dependencies.

The companion connects to the existing session service or launches it under macOS's kernel-backed `lockf` utility. Local sockets live in a private user-owned directory, with no extra LAN listener or OS service registration. A versioned runtime under `SLOPZOOKA_HOME/session-runtimes` retains Node and native PTY helpers across app replacement. Only the service holding the lifetime lock prunes inactive runtimes at startup. Incompatible services are left running, and the Mac menu retains diagnostics and explicit restart controls. Logs share [`SLOPZOOKA_HOME/logs`](mac-companion.md#diagnostics). Each process owns its writer; diagnostics never own terminal lifetime or require another daemon. The session service reports its actual log path; a retained writer is never relocated implicitly. Older services keep their legacy log until explicitly restarted.

Workspace display names and stable default window labels live in the Mac workspace index, using its existing serialized mutations and atomic writes. `workspace.ts` enriches HTTP session summaries with project/workspace context and defaults, including sessions from an older retained service. Explicit window renames remain with `SessionManager`; `names.ts` shares the normalization and validation. Naming metadata does not own process or window lifetime. Workspace renames keep Git branches and worktree paths unchanged. Native naming uses one voice controller and gateway route for both targets. Metadata naming availability is independent of renderer readiness and terminal input focus; scene inactivity still pauses capture. The header uses the same diagonal geometry for divider lines, hit targets, and full-height hover fills, clipped once to its outer glass shape; a forced session refresh rejects pre-mutation replies and also works for windows tied to another accepted Mac.

## Terminal transport

The stream uses ordered cursors, a bounded replay buffer, and headless xterm screen checkpoints. Clients acknowledge output after rendering. Slow viewers receive a checkpoint when their replay history expires. The host bounds parser input with PTY pause/resume and bounds each viewer's outstanding output. Checkpoints retain 1,000 scrollback lines; they are not an archival transcript. The terminal serializer is experimental, so unusual terminal extensions still need device validation.

The session service detects BEL, OSC 9, and OSC 777 notifications through the same headless parser. Optional `notificationSequence` counters accompany output frames and attachment checkpoints so alert state survives replay eviction. `TerminalConnection` forwards advancing counters through the WebView bridge; `WindowGateway` owns per-window unread acknowledgements. Native selection clears the indicator, and each terminal controller anchors its chime to its native scene using the player’s [scene-anchored spatial experience](https://developer.apple.com/documentation/audiotoolbox/spatializing-sound-from-a-uiscene). Reattachment restores unread state silently.

Terminal dictation uses hold-to-talk with a controller-owned three-second cancellation window after final transcription. The centered draft fades in place, × cancels, and acknowledged delivery emits a click and border pulse. Recognition pauses and task rotation preserve the draft until release; disconnect/background cancels the countdown and preserves unsent text. The standalone Voice Playground target references the same native voice sources and substitutes local delivery.

Dictation carries a command ID. A retried request is deduplicated within the most recent 1,000 input commands for that session. IDs cannot be reused with different text.

`terminal-text-input.ts` handles committed hardware text when WebKit omits `keypress`. It observes xterm’s public `onKey` event to suppress duplicate `beforeinput` delivery, forwards through `Terminal.input` and the existing ownership-aware transport, and leaves composition events and screen-reader editing with xterm. Pending strokes clear on keyup, blur, and composition boundaries; listeners detach with the terminal document. Native key normalization supplies missing codes for named terminal keys and Control combinations, preserving modifiers while xterm owns sequence encoding.

## Vision client ownership

Paths below are relative to `apps/vision-client/SlopZooka/SlopZooka`.

| File                                                              | Responsibility                                                                                                                             |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `WindowGateway.swift`                                             | Window intent, session launch/end, content resolution, reload, and recovery; starts the shared client from any restored scene |
| `WindowPersistence.swift`                                         | Layout synchronization and the pending local outbox                                                                                        |
| `WindowScene.swift`                                               | Native scene actions and lifecycle; permanent discards record close intent, disconnect/background events update presence                   |
| `CompanionClient.swift`                                          | Mac discovery, accepted host identity, pairing, connection state, refresh lifetime, and typed native control requests                         |
| `LauncherState.swift`                                             | Shared project browsing and launch state                                                                                                   |
| `CompanionWebView.swift`                                          | `TerminalSessionController` and the terminal WebView bridge                                                                                |
| `BugReportView.swift` / `BugReportState.swift` | Native voice composition and explicit review from the terminal menu; rejected reviews can be renewed, uncertain submissions cannot be retried |
| `TerminalVoiceController.swift` / `SpeechCaptureController.swift` | Shared terminal, naming, and local-composition voice state with one microphone owner                                                                                                   |

`CompanionClient.swift` owns discovery, accepted routes, pairing, connection state, and native HTTP requests. Any scene can start it through `WindowGateway`, independently of the launcher. Views observe the client; the gateway consumes session snapshots for window recovery. Control callers pass stable host IDs. Health/protocol checks accept a route, and route revisions reject late replies even when an address changes away and back. Replacement routes can refresh while an old request is stalled; network failures publish reconnecting state until a request succeeds.

Each Mac has one shared frontend catalog and poll, independent of session polling and other Macs. Launcher and workspace views read that catalog without local copies or timers. Concurrent reads coalesce; URL edits refresh the shared catalog and supersede older reads. Both poll types use the same client-lifetime loop.

Pairing credentials are keyed by host ID in Keychain. Separate trusted-origin bindings restrict where those credentials may be sent; a matching ID from unauthenticated discovery or health never authorizes a new origin. Successful legacy authentication migrates the existing origin credential. A new origin requires explicit pairing until an authenticated transport can establish route trust. Pairing uses the accepted route and saves credentials only while that selection is current.

The client's injected request exchange exercises the production routes, bodies, timeouts, authentication, and decoding in native checks. Response models contain only consumed fields and use standard JSON decoding; unused Mac metadata is ignored. Control and terminal content use a route-owned native transport described below. Arbitrary preview WebView networking remains separate and is available only on qualified Local Network routes. Window intent, persistence conflicts, and process lifetime stay with their existing owners.

`LauncherState` represents its mutually exclusive project operations with one operation value. Workspace commands share their operation guard, error handling, and catalog refresh. Repository and workspace catalogs use `CatalogState<Value>` and one loader; loaded data is part of the state, with no separately maintained arrays or counts. Connection changes reset catalogs and cancel their shared parent task. The three catalogs load concurrently, independently of window recovery; connection and request identities reject superseded results.

`WindowGateway` keeps one ephemeral state record per window: stable reference, terminal or preview content, native presence, notifications, errors, and pending work. The record owns reload and unavailable-session cleanup, including invalidating pending renames. Its reload revision also versions preview resolution, replacing a separate refresh list. Newer resolutions replace cancelled work immediately and reject late results and cleanup; the current payload remains available during reload. Durable intent remains solely in `WindowPersistence`.

New window kinds and lifecycle behavior extend the existing gateway and persistence path. Persist stable content identifiers; resolve URLs, tokens, and trust material when needed. visionOS owns physical placement. See [AGENTS.md](../AGENTS.md) for the full window invariants.

## Companion transport

`CompanionClient` owns selected method and accepted identity; `CompanionTransportRoute` owns one ephemeral loopback origin, URLSession, and native streams. With transport-v1 companions, native APIs and the terminal WebView (including its assets and WebSocket) use this origin, retaining the existing xterm connection state machine. Older companions keep their LAN origin so preview certificate names remain compatible; their control URLSession is still route-owned. Local Network forwards to the existing Mac HTTP listener. Direct uses certificate-authenticated TLS 1.3 and the native peer ingress. Loopback credentials are in memory, revoked on retirement, and never stored as trusted Keychain origins or window URLs.

`packages/transport/NativeStream.swift` supplies bounded, independently backpressured byte streams for both apps. Its mutable state is confined to one dispatch queue, explicitly separate from the UI's main actor. `apps/mac-companion/src/companion-transport.ts` owns the optional native helper's lifetime, private backend ingress, TLS identity, retries and renewal; `native/TransportHost.swift` owns peer-aware listening and per-socket interface admission. It forwards to existing handlers and never owns sessions or reimplements domain APIs. The helper requires macOS 15+ for memory-only TLS identity import. Packaged and development builds include it; absent/unavailable helpers leave Local Network functional.

Control, pairing, and diagnostics delivery share `CompanionClient.send` and the explicit route's `exchange`; retired routes reject further sends. The static origin map supplies only WebView credential bindings and never selects a URLSession. Request tracing stays above delivery, so diagnostics uploads do not trace themselves.

Native byte streams expose one metadata callback, not a logging subsystem. Headset observations enter injected `AppLog`; helper observations cross bounded, versioned stdout frames and enter the companion's scoped `transport` logger. Listener lifetime, helper recovery, method changes, the first admitted peer interface, and first failures per finite stream stage are logged; successful channels and repeated failures are summarized on listener retirement. No per-packet events or payloads. Waiting byte channels fail to their existing request/WebSocket owner, which decides whether a retry is safe. EOF from either endpoint ends a fixed HTTP/WebSocket channel after forwarding final bytes; both native connections are released. Independent half-close tunnels are outside this adapter’s contract. HTTP and terminal upgrade diagnostics attribute the actual accepting ingress.

Manual method changes retire documents and old requests before connecting again. `WindowGateway` clears live payloads while preserving scene and desired-layout identities. `presentation.ts` supplies a per-request availability result to frontend catalogs and enforces the same result on Open. It uses the accepting ingress, not caller-supplied route claims. An old frontend's `transport: direct` means a direct URL and does not mean a peer connection. The initial peer route disables arbitrary web previews. The gateway also consults this catalog capability during restoration: known unavailable content keeps its window intent and reason without repeatedly calling Open; later availability allows resolution. Optional missing availability fields retain known legacy Local Network behavior.

Direct's CA is learned only over an already authenticated Local Network route and stored against host identity. A matching discovery ID never grants credentials to an unverified peer. No silent cross-method fallback, generic arbitrary-port proxy, second terminal protocol, new window persistence owner, or media multiplexing through JSON is introduced. The [physical acceptance results](../.plans/2026-11-10-transport-device-results.md) establish AWDL admission and headset terminal use after a listener fix, and record a historical recovery-log discrepancy. The [local recovery follow-up](../.plans/2026-11-10-transport-recovery-followup.md) reproduces and fixes an EOF stall with two real WKWebViews. A [later headset rerun](../.plans/2026-11-10-native-preview-device-results.md#direct-recovery-functional-pass-bounded-idle-recovery-not-established) confirmed fresh input in both terminals after a helper restart without a method toggle; focus-related reconnect flashes leave unattended recovery timing unqualified. Travel, sleep/wake, media throughput, and bounded recovery for every window remain separate qualification.

## Native diagnostics

`apps/shared/Diagnostics.swift` owns the scoped `AppLog` facade, recent-entry ring, and bounded native outbox. `apps/shared/NativeLogFile.swift` is the serial Mac file writer; fresh segments avoid tail repair, with pruning only when opening a segment. Only the debug panel observes its published recent-entry ring; routing and delivery state do not publish changes. `CompanionClient` uploads host-scoped batches through existing pairing credentials; first-party terminal WebViews forward events through a validated main-frame bridge. Both native targets compile the shared runtime directly, without depending on another application’s source folder. Diagnostics use an additive versioned envelope and a shared fixture in `packages/protocol`, independently of the terminal protocol version.

## Design history

The [original product brief](archive/PLAN.md) and [v0 implementation plan](archive/EXEC_PLAN.md) record early decisions and superseded terminology. They are historical context. Current behavior is documented here and in the usage guides; feature-specific plans live in [`.plans`](../.plans).

## Native window previews

Experimental window capture reuses the frontend catalog, authenticated companion
route, Preview scene, `WindowGateway`, and existing layout schema. A preview stores
an observed source ID; URLs, pairing credentials, media tickets, and geometry never
enter its durable layout record. Native reload retires the old viewer before
resolving fresh content. `WindowScene` owns aspect requests and per-scene geometry
preferences, independently of encoded pixel resolution.

`window-previews.ts` owns a narrowly signed native capture child and its bounded
control IPC. `WindowHost.swift` enumerates sources and grants short-lived, single-use
loopback tickets. `WindowCaptureViewer.swift` captures ScreenCaptureKit output and
hardware H.264 for each independent viewer. It never launches/quits source apps,
injects input, or owns PTYs. Provider restart invalidates source IDs rather than
matching by title. Closing the last viewer releases that viewer's capture resources.
The current implementation has one capture/encoder per viewer, capped at eight;
hardware capacity at that limit is not qualified.

Control replies use the existing HTTP authentication. One fixed HTTP upgrade
forwards opaque binary media between the accepted route and native provider, using
Node stream backpressure; it is not an arbitrary-port proxy or JSON video path.
`packages/media` supplies the bounded versioned packet parser, frame-credit and
keyframe rules, VideoToolbox adapter, and native receiver. Each viewer permits two
outstanding frames and a one-second ACK/encode deadline. Waiting/idle heartbeats
receive separate acknowledgements, which cannot grant frame credit; silent viewers
are closed after two seconds even when the source is static. Receiver enqueue acknowledgements
are not proof of physical display. A stalled renderer drops its old connection
instead of replaying a backlog. Native flow control stays separate from terminal
flow control. Native video uses this same route on Local Network and Direct: the catalog and
Open depend on capture state, not connection method. The peer ingress forwards
the same authenticated binary upgrade; no separate media transport or endpoint
is introduced. A [physical check](../.plans/2026-11-10-direct-native-video-results.md) passed two
Direct streams, real terminal input, app restart and LAN return. Capacity, travel,
sleep/wake and measured display latency remain unqualified.

The provider emits bounded lifecycle summaries into the companion's existing
`window-previews` logger. No image data, window titles, user input, or media tickets
are logged. `NativePreviewModel` owns only its live receiver/decoder and three bounded
reconnect attempts. Route retirement cancels its channels. Source/permission failure
requires the displayed repair action; it does not create another window registry or
restart policy for the source application.

Native capture provider callbacks run outside request-local log context because
the provider outlives its first catalog call. Bridge open/close events carry the
actual accepting route and a connection ID through the same injected logger.
Provider media summaries remain route-neutral; they must not inherit the route
of whichever request happened to start the child.

### Terminal preview intent adapter

`preview-control.ts` is a stateless adapter over the authenticated frontend catalog
and client-scoped window-layout API. `preview-mcp.ts` exposes its four operations
through SDK stdio. Explicit local companion identity, pairing credential and headset
client binding stay in a private operator configuration; model arguments contain
only observed source IDs, preview IDs and names. Automatic terminal launch-context
provisioning remains a later integration step.

Remote close is reconciled only after successful `WindowPersistence` synchronization,
using the fetched layout plus pending local intent. `WindowGateway` retires payloads,
cancels resolves and asks `WindowScene` to dismiss; failed reads and disconnects never
imply close. A close observed while no scene can present is delivered when a presenter
attaches. Optional window `name` metadata participates in persistence equality, while
`WindowReference` hashing/equality uses stable host/content identity so archived scenes
with old labels cannot discard renamed replacements. Names render through gateway
state without changing the video reload revision.
