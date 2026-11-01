# Architecture

[Back to README](../README.md) · [Development](../CONTRIBUTING.md)

The Mac owns workspaces and terminal processes. The headset owns native presentation and input. The HTTP companion connects them; a separate local session service keeps terminals alive when the companion restarts.

## Repository map

| Path                                                | Responsibility                                                                  |
| --------------------------------------------------- | ------------------------------------------------------------------------------- |
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
| `sessions.ts`                            | `SessionManager`: PTYs, screen state, replay, resize ownership, and input deduplication; instantiated only by the session service |
| `session-service.ts`                     | Private service entry point, terminal dispatch, shutdown, and lock-protected socket/runtime cleanup                               |
| `session-service-client.ts`              | Connect-or-start, retained runtime installation, HTTP control, and bounded viewer relay; no session registry                      |
| `session-service-protocol.ts`            | Versioned local control contract                                                                                                  |
| `window-layout.ts`                       | Client-scoped desired window layouts, atomic persistence, and revision checking                                                   |
| `workspace.ts`                           | Git worktrees and workspace persistence                                                                                           |
| `github.ts`                              | Repository discovery and creation through GitHub                                                                                  |
| `dashboard-address.ts`                   | Optional Portless dashboard alias, verified redirects, and localhost fallback                                                     |
| `frontend-discovery.ts`                  | Read-only Portless adapter, listener inventory, and bounded HTTP probes                                                           |
| `frontends.ts`                           | Unified frontend catalog, saved URLs, and preview gateways                                                                        |
| `project-frontends.ts`                   | Workspace frontend configuration and ownership matching                                                                           |
| `harness.ts`                             | Browser dashboard                                                                                                                 |
| `terminal.ts` / `terminal-connection.ts` | Browser terminal renderer, reconnect, and ordered rendering                                                                       |

[`scripts/build-mac-app.mjs`](../scripts/build-mac-app.mjs) packages the signed Mac app. [`build-session-runtime.mjs`](../apps/mac-companion/scripts/build-session-runtime.mjs) builds the retained terminal runtime using existing dependencies.

The companion connects to the existing session service or launches it under macOS's kernel-backed `lockf` utility. Local sockets live in a private user-owned directory, with no extra LAN listener or OS service registration. A versioned runtime under `SLOPZOOKA_HOME/session-runtimes` retains Node and native PTY helpers across app replacement. Only the service holding the lifetime lock prunes inactive runtimes at startup. Incompatible services are left running, and the Mac menu retains diagnostics and explicit restart controls. Logs are in `SLOPZOOKA_HOME/session-service.log`.

## Terminal transport

The stream uses ordered cursors, a bounded replay buffer, and headless xterm screen checkpoints. Clients acknowledge output after rendering. Slow viewers receive a checkpoint when their replay history expires. The host bounds parser input with PTY pause/resume and bounds each viewer's outstanding output. Checkpoints retain 1,000 scrollback lines; they are not an archival transcript. The terminal serializer is experimental, so unusual terminal extensions still need device validation.

Dictation carries a command ID. A retried request is deduplicated within the most recent 1,000 input commands for that session. IDs cannot be reused with different text.

## Vision client ownership

Paths below are relative to `apps/vision-client/SlopZooka/SlopZooka`.

| File                                                              | Responsibility                                                                                                                             |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `WindowGateway.swift`                                             | Window intent, session launch/end, content resolution, reload, and recovery; shared discovery/refresh lifetime independent of the launcher |
| `WindowPersistence.swift`                                         | Layout synchronization and the pending local outbox                                                                                        |
| `WindowScene.swift`                                               | Native scene actions and lifecycle; permanent discards record close intent, disconnect/background events update presence                   |
| `HostConnection.swift` / `CompanionAPI.swift`                     | Connection identity and authenticated requests                                                                                             |
| `LauncherState.swift`                                             | Shared project browsing and launch state                                                                                                   |
| `CompanionWebView.swift`                                          | `TerminalSessionController` and the terminal WebView bridge                                                                                |
| `TerminalVoiceController.swift` / `SpeechCaptureController.swift` | Voice-input state and microphone capture                                                                                                   |

New window kinds and lifecycle behavior extend the existing gateway and persistence path. Persist stable content identifiers; resolve URLs, tokens, and trust material when needed. visionOS owns physical placement. See [AGENTS.md](../AGENTS.md) for the full window invariants.

## Design history

The [original product brief](archive/PLAN.md) and [v0 implementation plan](archive/EXEC_PLAN.md) record early decisions and superseded terminology. They are historical context. Current behavior is documented here and in the usage guides; feature-specific plans live in [`.plans`](../.plans).
