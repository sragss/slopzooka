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

The client's injected request exchange exercises the production routes, bodies, timeouts, authentication, and decoding in native checks. Response models contain only consumed fields and use standard JSON decoding; unused Mac metadata is ignored. Terminal WebSockets and preview WebView networking remain separate content transports. Window intent, persistence conflicts, and process lifetime stay with their existing owners.

`LauncherState` represents its mutually exclusive project operations with one operation value. Workspace commands share their operation guard, error handling, and catalog refresh. Repository and workspace catalogs use `CatalogState<Value>` and one loader; loaded data is part of the state, with no separately maintained arrays or counts. Connection changes reset catalogs and cancel their shared parent task. The three catalogs load concurrently, independently of window recovery; connection and request identities reject superseded results.

`WindowGateway` keeps one ephemeral state record per window: stable reference, terminal or preview content, native presence, notifications, errors, and pending work. The record owns reload and unavailable-session cleanup, including invalidating pending renames. Its reload revision also versions preview resolution, replacing a separate refresh list. Newer resolutions replace cancelled work immediately and reject late results and cleanup; the current payload remains available during reload. Durable intent remains solely in `WindowPersistence`.

New window kinds and lifecycle behavior extend the existing gateway and persistence path. Persist stable content identifiers; resolve URLs, tokens, and trust material when needed. visionOS owns physical placement. See [AGENTS.md](../AGENTS.md) for the full window invariants.

`apps/shared/Diagnostics.swift` owns the scoped `AppLog` facade, recent-entry ring, and bounded native outbox. `apps/shared/NativeLogFile.swift` is the serial Mac file writer; fresh segments avoid tail repair, with pruning only when opening a segment. Only the debug panel observes its published recent-entry ring; routing and delivery state do not publish changes. `CompanionClient` uploads host-scoped batches through existing pairing credentials; first-party terminal WebViews forward events through a validated main-frame bridge. Both native targets compile the shared runtime directly, without depending on another application’s source folder. Diagnostics use an additive versioned envelope and a shared fixture in `packages/protocol`, independently of the terminal protocol version.

## Design history

The [original product brief](archive/PLAN.md) and [v0 implementation plan](archive/EXEC_PLAN.md) record early decisions and superseded terminology. They are historical context. Current behavior is documented here and in the usage guides; feature-specific plans live in [`.plans`](../.plans).
