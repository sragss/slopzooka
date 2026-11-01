# SlopZooka

Spatial coding for Apple Vision Pro. Your Mac owns terminal processes and workspaces; the headset opens windows onto them. Frontends appear from local web servers, your existing Portless registry, or saved URLs.

## Mac menu-bar app

Build once on macOS with Node.js 22+, pnpm, and Xcode:

```sh
pnpm install
pnpm build:mac-app
```

Builds stage and verify a complete signed bundle before replacing the last good build. A failed compile leaves the previous app intact. Quit an app running directly from `build/mac-app` before rebuilding; the build refuses to overwrite a live app.

Move `build/mac-app/SlopZooka.app` to Applications and open it. It lives in the menu bar, with a pairing code, terminal/frontend counts, **Open Dashboard**, **View Logs**, and **Start at Login**. The connection code is always visible for headset pairing; **Open Dashboard** signs your browser in automatically. Login startup and logs live under **Settings**. It does not occupy the Dock. Login startup is opt-in through macOS's login-item service; if macOS requires approval, the app links to Login Items settings.

The app bundles Node, production dependencies (including native PTY support), and the compiled companion. Running it does not require the repo, pnpm, or an installed Node. Your project tools (`git`, `gh`, Codex, etc.) still need to be installed. The app loads your login-shell PATH with a bounded timeout so tools managed by nvm/mise/pnpm remain available when launched from Finder.

Closing the menu or choosing **Quit** leaves terminal sessions and their processes running. The menu owns the HTTP companion; its private parent/child pipe stops that companion if the UI exits or crashes. A separate local session service owns the PTYs and screens, so reopening the menu or restarting the HTTP companion reconnects to the same sessions. **Settings → Restart Companion** is safe for running terminals. **Restart Session Service** and **End All Sessions and Stop Service** explicitly end sessions and their descendants after confirmation. A companion crash triggers bounded restart attempts without restarting the session service. A host that never finishes startup is stopped after 15 seconds, with force termination five seconds later if it ignores shutdown; the UI remains available to retry. A pre-existing companion on the same port is left alone: stop the Terminal-launched host before switching to the app. Pairing credentials remain in the same `~/.slopzooka` store.

The build uses an available Apple Development / Developer ID certificate so its signing identity survives updates and macOS can retain folder permissions. Set `SLOPZOOKA_SIGN_IDENTITY` to a specific identity when multiple teams are installed. Without a certificate, the build stops with setup guidance; `SLOPZOOKA_SIGN_IDENTITY=-` explicitly permits an ad-hoc test build, whose privacy permissions may reset after every rebuild. Run the app from Applications rather than from a repository inside Documents or Downloads. The bundle targets the build machine's architecture. Distribution to other Macs still requires Developer ID signing/notarization. `pnpm test:mac-app` verifies the signed bundle, packaged static assets and PTY, private status channel, the same shell PID across UI/HTTP restarts, spawning after the old app runtime is removed, and force termination of a hung startup using an isolated home and port. It does not enable login startup or modify your live companion.

## Vision Pro and development

Open `apps/vision-client/SlopZooka/SlopZooka.xcodeproj` in Xcode and run the headset app. Bonjour discovers the companion. When pairing is needed, the code briefly appears centered on the Mac without taking keyboard focus. The headset focuses its six-digit input and submits automatically; it saves the credential in Keychain. The Mac menu remains a fallback. The display dismisses after 45 seconds, successful pairing, or an authenticated reconnection by the device that requested it. Late display requests from a recently connected device do not reopen the prompt; other devices can still pair. Repeated display requests are limited to once per minute. Manual host/IP entry remains available behind Enter address manually. A verified IP is never rewritten into an untested hostname.

The headset launcher separates **Terminals**, **Projects**, and **Frontends**, and remembers your last tab. Project search and the tool selector are visible together. Use the launcher’s **Settings** gear for Mac connection controls and troubleshooting; connection status remains visible in the header. Terminal windows keep frontend and dictation controls visible; shell creation, details, and ending a session live under the actions menu.

Terminal zoom ranges from **10% to 200%**. **Settings → Default terminal zoom** starts at **60%** and persists across app launches. Terminals without a custom zoom follow that default; existing scene zoom preferences are preserved. Reset Zoom applies the current saved default. The actions menu groups zoom out, zoom in, and reset into one row of magnifying-glass icons, with the percentage at the far right. Full button cells share their tap and hover bounds; zoom actions keep the popover open for repeated adjustments. Zoom changes the terminal font size and explicitly refits the emulator and PTY while keeping the web view full size. Older Mac companions without the font-zoom bridge use a scaled logical viewport so their resize observer still refits the terminal. Update both apps for the bounded emulator/PTY grid at extreme zoom.

**Settings → Persistent voice input** is off by default. Turn it on, then look at the mint microphone button at the terminal’s bottom right and pinch to start. A small transcript dock beside the button and a listening border mark the destination. The listening waveform follows microphone energy and settles during silence; no audio is retained for this visual feedback. Pauses keep your draft; **Send** submits it with Return and starts listening for the next message. Select another terminal’s microphone to switch when the draft is empty, or send/discard the draft first. **Stop** releases the microphone and discards the draft. The same explicit selection works in normal and immersive workspaces; there is no automatic head or eye targeting. Turning the setting off restores one-shot dictation, which sends after a short pause. Listening never restores on launch. Losing the connection or scene activity pauses capture and keeps the draft; reconnecting requires **Resume** or **Retry**. Retry preserves the command ID to avoid duplicate input after an uncertain acknowledgement.

**Settings → Immersive workspace** adds an optional wrist menu at runtime. It opens the launcher and up to three recent terminals through the same window gateway. Choose either wrist; exit from Settings or the wrist menu. Your room and SlopZooka windows remain visible while other apps are hidden. Immersion starts off on each launch. The simulator shows a stationary version of the same menu; physical wrist tracking and comfort require Vision Pro validation. See [.plans/2026-10-31-immersive-workspace.md](.plans/2026-10-31-immersive-workspace.md) for architecture, scope, and device checks.


For companion development, run `pnpm dev:companion` instead of the menu-bar app. This prints the pairing code in Terminal. Open `http://localhost:7777/dashboard` for the desktop dashboard and pair with the same code.

`pnpm dev:companion` does **not** restart on source changes. Use `pnpm --filter @slz/mac-companion dev:watch` to restart the HTTP companion on changes while the same session service keeps its terminals running. Terminal-engine changes require an explicit session-service restart, which ends its sessions. Rebuild the Mac app after changing its bundled host or native code.

Run production and development companions with different `SLOPZOOKA_HOME` directories and ports. Set `SLOPZOOKA_PORTLESS=0` for an isolated development instance. There is one session service per canonical home, independent of the HTTP port; never run two HTTP companions against the same home. `/health` identifies development versus packaged code. Builds can use `SLOPZOOKA_BUILD_DIR` to stage an independent app bundle without replacing the one under test.

The companion connects to the existing session service or launches it under macOS's kernel-backed `lockf` utility. Local sockets live in a private user-owned directory, with no extra LAN listener or OS service registration. A versioned runtime under `SLOPZOOKA_HOME/session-runtimes` retains Node and native PTY helpers across app replacement. Only the service holding the lifetime lock prunes inactive runtimes at startup. Incompatible services are left running, and the Mac menu retains diagnostics and explicit restart controls. Logs are in `SLOPZOOKA_HOME/session-service.log`.

### Window recovery and iteration while wearing the headset

The companion saves the intended set of terminal and preview windows in
`SLOPZOOKA_HOME/window-layouts.json`, separately for each headset installation's
client ID. Update both apps to use this feature. The headset keeps a small outbox
of unacknowledged open/close changes, so a disconnected close or interrupted save
can be retried after reconnecting. A native rebuild over the existing installation
retains that client ID; deleting the app's data creates a different client.

Every scene can start recovery, including when the launcher is closed. Existing
system-restored windows resolve their content again; missing intended windows are
opened once. Closing a window updates the saved layout without ending its terminal
process. Backgrounding, disconnecting, or rebuilding the headset app does not close
the saved windows. HTTP companion restarts preserve sessions. Sessions lost to a session-service
restart remain unavailable; recovery never silently launches replacement shells. Preview windows resolve fresh gateway
URLs and trust material from the Mac, including after detecting a new HTTP companion
instance. Cookies and browser navigation history still
belong to the WebView and do not survive native process replacement.

visionOS owns physical placement and room locking. Recovery preserves scene IDs
and reuses restored scenes, but opening a missing window is not a guarantee of its
previous physical position. Xcode stop/run, installation over an existing app,
system-close behavior, and locked/unlocked room placement require device testing.

For terminal web UI development, keep `pnpm dev:companion` running and run
`pnpm --filter @slz/mac-companion dev:web` in another terminal. The watcher rebuilds
browser assets without restarting the host or its PTYs. Use **Reload Content** in
a terminal's actions menu, or the launcher's reload button for all visible windows.
This reloads content inside the same native scenes. Preview reload also refreshes
its gateway connection while keeping the WebView. Swift changes still require a
native build; this workflow does not inject Swift code into a running app. The
packaged Mac app serves its bundled assets, so use the development companion for
this workflow.

**Named dashboard:** When an installed Portless proxy is configured, the companion automatically registers `slopzooka.localhost` through `portless alias`. **Open Dashboard** checks that the named route reaches this companion, then redirects there; if Portless is absent, stopped, misconfigured, or the name belongs to another port, it opens the regular localhost dashboard. The companion keeps running on its own port and Bonjour continues to advertise the Mac’s LAN address for Vision Pro. `.localhost` is for browsers on the Mac.

The named URL follows the existing proxy: `https://slopzooka.localhost` on HTTPS port 443, or e.g. `https://slopzooka.localhost:1355` on a custom port. SlopZooka does not restart the shared proxy, change its port, install Portless, or alter certificate trust. The static alias remains available across companion restarts. If Safari cannot resolve a `.localhost` name, use Portless’s `hosts sync` setup or the direct localhost URL. Set `SLOPZOOKA_PORTLESS=0` to disable the dashboard alias. Opening from the menu signs the browser in at the selected hostname. Visiting a dashboard URL directly still requires pairing once per browser and hostname.

Portless is optional. The registry adapter is tested against the Portless 0.14 schema; use the Node version required by your installed Portless when running Portless itself.

## Terminal lifecycle

- A workspace is a git worktree. Each workspace can have multiple independent terminal sessions.
- Opening a session attaches a viewer. Closing a window or losing the network detaches it without killing the process.
- Sessions reappear in the launcher after restarting the headset app. Reopening restores the current screen, including the alternate screen used by TUIs.
- **New Shell** adds a terminal to the same workspace. **End Session** explicitly stops the process and its current descendants. Ending an already exited session removes its retained screen.
- Sessions survive client disconnects and menu/HTTP companion restarts. They do not survive session-service crashes/restarts or Mac reboots. Processes continue running until explicitly ended or the session service stops.
- One viewer controls keyboard input and terminal size. Additional viewers are read-only; control transfers when the controlling viewer detaches. Native dictation is an authenticated host command and is ordered with keyboard input.

The stream uses ordered cursors, a bounded replay buffer, and headless xterm screen checkpoints. Clients acknowledge output after rendering. Slow viewers receive a checkpoint when their replay history expires. The host bounds parser input with PTY pause/resume and bounds each viewer's outstanding output. Checkpoints retain 1,000 scrollback lines; they are not an archival transcript. The terminal serializer is experimental, so unusual terminal extensions still need device validation.

Dictation carries a command ID. A retried request is deduplicated within the most recent 1,000 input commands for that session. IDs cannot be reused with different text.

## Frontends

Start your app normally (`next dev`, Vite, Python, or another HTTP server). The Mac companion inspects TCP listeners owned by your user and makes bounded HEAD requests to find web servers on arbitrary ports. It does not scan a list of guessed ports or require binding your app to the LAN. The launcher and terminal frontend panel update automatically.

There is one list and one Open action for three sources:

- **Local servers:** HTTP listeners appear after their first response, labeled with their working directory (or process name) and port. An existing app shows “Waiting for response” while its listener is unresponsive and “Stopped” for up to one minute after its listener disappears. Any HTTP response establishes availability, not application health. Discovery excludes the companion itself and known Portless proxy/backend ports, and deduplicates IPv4/IPv6 listeners owned by the same process. It checks at most 128 listeners, eight at a time, with an 800 ms probe deadline. Workspace ownership uses the canonical listener directory and exact worktree boundaries, independently of the display label.
- **Portless:** Keep using your usual workflow. SlopZooka reads `routes.json` and the proxy's port/TLS/LAN state from `PORTLESS_STATE_DIR` or `~/.portless`. Named routes retain their identity across backend port changes. Registration is not a health check. The adapter never starts, stops, reconfigures, or writes Portless state.
- **Saved URLs:** Use **Add URL** on the headset or host page for custom URLs, HTTPS servers, and deployed previews. Local addresses use the Mac gateway; remote URLs open directly on the headset, preserving their origin and path. Saved URLs persist in `SLOPZOOKA_HOME/frontends.json`; remove them with the headset's context menu or the host page's Remove button. Embedded credentials and non-HTTP(S) URLs are rejected. Local/remote classification happens when a URL is added; re-add it if its DNS destination changes between machines.

**Workspace frontends (optional configuration):** Servers inside a managed worktree automatically appear beside that workspace and its terminals. This works with ordinary HTTP servers and Portless; no config or special launch command is required. Nested packages belong to their containing worktree, and simultaneous worktrees remain separate. The host dashboard offers an Open app button or a frontend picker; Vision Pro terminals show a workspace-only frontend popover. Apps without an identifiable workspace remain available in the global Frontends tab.

For explicit names and a preferred frontend, commit `.slopzooka.json` at the worktree root:

```json
{
  "version": 1,
  "frontends": [
    { "id": "web", "name": "Website", "directory": "apps/web", "default": true },
    { "id": "admin", "name": "Admin", "directory": "apps/admin" }
  ]
}
```

The file is optional. Missing `frontends` means automatic discovery; `"frontends": []` explicitly disables workspace frontend controls. `directory` defaults to `"."`, `name` defaults to `id`, and at most one entry can be the default (sorted first). Directories must stay inside the worktree, including symlink targets. The most specific matching directory supplies the label. Extra discovered servers remain accessible globally. Ambiguous directory/endpoint matches retain their URLs and produce a diagnostic instead of silently selecting a winner. Configuration errors include the file path and original reason, while automatic discovery continues. Changes take effect on the next catalog refresh.

Configuration describes browser surfaces, not running processes: it never launches a server or displays an invented startup state. Your agent or shell still runs the project's usual dev command. This initial schema intentionally contains only frontend hints; command orchestration and runtime registration are not part of it. Processes without a discoverable directory, remote previews, and containers may remain unassigned. Multiple surfaces sharing a directory or process can still be opened through the global catalog / Add URL; directory hints cannot distinguish their roles. No repository-name or port-number-only ownership guesses are made. Changing a route's workspace invalidates its existing preview gateway.

All local routes share one authenticated HTTP(S)/WebSocket gateway implementation. Loopback-only servers remain reachable from the headset. HTTPS apps stay HTTPS between the Mac and headset, preserving Secure and HttpOnly login cookies and secure WebSockets. The companion generates a private preview CA under `SLOPZOOKA_HOME/preview-tls` using `openssl`; private keys are stored with owner-only permissions. The authenticated open response supplies the public CA to the headset, which validates the certificate chain, hostname, and expiry only at that preview's exact host and port. This does not install a system CA or change trust for external navigation. Pairing and the control API still require a trusted local network. Update both apps to use HTTPS previews; the new headset client rejects an older companion's HTTP downgrade. The Mac dashboard opens HTTPS apps at their original address, using the browser's existing trust.

Portless gateways forward through the existing proxy with the named Host header and verify upstream HTTPS using Portless's CA. Ordinary local HTTPS URLs use Node's trusted CAs; private CAs must be trusted by Node (for example through `NODE_EXTRA_CA_CERTS`). There is no certificate-verification bypass. Automatic listener discovery currently detects HTTP; add HTTPS URLs explicitly.

Registered Portless `.local` frontends open directly when LAN mode is enabled. The headset must trust their certificate and the app must accept the LAN origin. Other remote/deployed URLs likewise use the headset's normal browser certificate validation.

The catalog prioritizes named Portless apps, saved URLs, and local project servers whose root responds with HTML or a redirect. JSON, unknown, and HTTP services without a detected project remain available under **Other services**. Local process working directories are matched to the nearest package or Git repository for project labels. Add a URL to keep an unusual app in the primary list. Exact saved/named URLs and discovered backend listeners are deduplicated.

Local preview gateways survive short server restarts (up to the 60-second discovery retention window), keeping their URL and cookie. Failure pages offer Reload and expandable upstream diagnostics; discovery warnings and gateway errors retain their original details in logs.

Gateway bootstrap preserves a saved URL's path, query, and fragment. HTTP bodies stream without buffering and WebSocket upgrades pass through. A response-header timeout protects against stalled upstreams without imposing an idle timeout on established streams. Repeated/concurrent opens reuse the listener. Preview reload keeps its WebView, cookies, and navigation history; frontend failures do not block terminal-list recovery.

Gateways preserve normal application Authorization headers and cookie security flags, remove SlopZooka credentials before forwarding, translate same-origin redirects/CORS responses and request origins/referrers, and isolate frontend cookie stores in the native app. They do not rewrite JavaScript, absolute cross-service URLs, or OAuth callback URLs embedded inside third-party redirects. Apps requiring those features should use native LAN routing with appropriate origins and certificate trust. Local gateways are intended for a trusted development network, not internet exposure.

Discovery sources fail independently: invalid Portless state produces a warning and preserves its last valid routes without preventing ordinary local servers or saved URLs from opening. Configuration changes are validated before commit; opens, refreshes, saved-URL mutations, and shutdown share one serialized lifecycle. Disappearing/stopped routes close their listeners and upgraded sockets. Changes to a route's upstream or transport invalidate only that route's gateway; reopen the frontend to obtain its replacement URL. A missing Portless installation is normal and produces no warning.

## Host configuration

| Variable | Purpose |
| --- | --- |
| `SLOPZOOKA_PORT` | Companion port, default `7777` |
| `SLOPZOOKA_PORTLESS` | Set `0` to disable automatic dashboard alias registration and redirection |
| `SLOPZOOKA_HOST` | Bind address, default dual-stack `::` |
| `SLOPZOOKA_HOME` | Workspace index, clones, worktrees, and pairing store; default `~/.slopzooka` |
| `SLOPZOOKA_LOG_DIR` | Override companion log directory |
| `SLOPZOOKA_CODEX_COMMAND` / `SLOPZOOKA_CLAUDE_COMMAND` / `SLOPZOOKA_OPENCODE_COMMAND` | Explicit agent command overrides |
| `PORTLESS_STATE_DIR` | Portless instance to discover |

Agent commands use their normal permission behavior. Previous implicit Claude permission bypassing has been removed.

HTTP companion shutdown closes public admission, viewer connections, and frontend gateways without stopping terminal ownership. Session-service shutdown closes its own admission before terminating session descendants. An in-flight launch may have succeeded even if an HTTP reply was lost; retry with the same session ID instead of launching another agent.

Opening the dashboard from the menu uses a single-use sign-in link, issued through the private app/companion pipe and valid for 60 seconds at the selected dashboard origin. The browser removes the link's fragment and exchanges it for an HttpOnly session cookie; the PIN and reusable credentials are never placed in the URL. Pairing credentials are hashed in a mode-600 host store. HTTP control endpoints require authentication; browser requests and WebSocket upgrades also enforce the companion origin. Connection codes contain six digits, expire after five minutes, and rotate on host restart. Pairing is limited to ten attempts per minute across the host; paired credentials persist. The named dashboard supports Portless HTTPS with Secure cookies and exact-origin validation limited to the registered hostname through a loopback proxy. Direct LAN control transport remains HTTP; pairing is an access boundary, not transport encryption. Do not publish the control port to the internet.

Workspace mutations are serialized within the companion and the index is replaced atomically. Run one companion per `SLOPZOOKA_HOME`. Existing indexes with `clusterId` are read and migrated to `workspaceId` on the next mutation. An explicit nonexistent branch now fails instead of silently selecting a different branch. Defaults follow the repository's default branch.

## Code boundaries

- `apps/mac-menu`: native SwiftUI menu-bar UI, child-process supervision, login item, and vector icon.
- `scripts/build-mac-app.mjs`: self-contained, locally signed macOS application bundle.

- `src/server.ts`: HTTP routes, authenticated WebSocket transport, discovery, and shutdown.
- `src/sessions.ts`: PTY ownership, screen state, attachment, replay, resize ownership, and input deduplication; instantiated only by the session service.
- `src/session-service.ts`: private service entry point, terminal protocol dispatch, explicit shutdown, and lock-protected stale socket/runtime cleanup.
- `src/session-service-client.ts`: connect-or-start, immutable runtime installation, typed HTTP control, and bounded per-viewer terminal relay. It keeps no session registry.
- `src/session-service-protocol.ts`: the small versioned local control contract.
- `scripts/build-session-runtime.mjs`: build the retained terminal runtime; no additional npm dependencies.
- `src/window-layout.ts`: authenticated, client-scoped window layouts with atomic persistence and revision checking.
- `src/dashboard-address.ts`: optional Portless dashboard alias, verified redirects, and localhost fallback.
- `src/frontend-discovery.ts`: read-only Portless adapter, macOS listener inventory, and bounded HTTP probes.
- `src/frontends.ts`: unified catalog, saved URLs, and frontend gateway lifecycle.
- `src/workspace.ts`: git worktrees and workspace persistence.
- `src/terminal-connection.ts`: browser reconnect and ordered rendering.
- `packages/protocol`: versioned terminal messages and runtime validation.
- Vision client: `WindowGateway` is the single entry point for window intent,
  session launch/end, content resolution, reload, and recovery. `WindowPersistence`
  owns layout synchronization and the local outbox. `WindowScene` alone adapts
  native window actions and scene lifecycle; permanent scene discards record close
  intent, while disconnect/background events only update live presentation state.
  `HostConnection`, `CompanionAPI`, the shared `LauncherState`, and
  `TerminalSessionController` handle connection identity, requests, project browsing,
  and the WebView bridge. The gateway owns the shared discovery/refresh lifetime,
  independent of the launcher view.

New window types and lifecycle features must extend this gateway/persistence path,
not introduce another registry or direct scene actions in views. Persist stable
content references, never resolved URLs, access tokens, focus, or physical poses.
See [AGENTS.md](AGENTS.md) for the architecture rules and verification expectations.

## Verify

```sh
pnpm typecheck
pnpm test
pnpm test:vision-state
pnpm test:terminal-keyboard
pnpm format:check
pnpm build:harness
xcodebuild -project apps/vision-client/SlopZooka/SlopZooka.xcodeproj \
  -scheme SlopZooka -sdk xrsimulator -configuration Debug \
  -derivedDataPath /tmp/slz-derived CODE_SIGNING_ALLOWED=NO build
```

Integration tests use temporary homes, real PTYs, and isolated HTTP/HTTPS/WebSocket fixtures. They do not modify your Portless registry, workspaces, or GitHub repositories. Tests cover authentication, malformed messages, reconnect/replay/checkpoints, output floods, multiple viewers, command deduplication, descendant cleanup, simultaneous workspace mutations, branch selection, and frontend listener lifecycle. Discovery tests include restart recovery with stable preview credentials, cancellation during shutdown, browser/service classification, project naming, a real macOS child server, non-HTTP exclusion, incremental SSE, WebSockets, Portless failure isolation, and saved-URL persistence. The TLS fixture requires `openssl`.

Before relying on a headset release, exercise these on physical Vision Pro: pair; open an agent and a shell in one workspace; close/reopen a window; sleep/wake the headset during output; dictate once while interrupting the connection; and open Next.js/Vite apps with HMR, auth, and cross-service requests. LAN certificate trust and framework origin policies require real-device verification.

`pnpm test:vision-state` runs the launcher state regression checks on macOS: dismissing repository creation immediately unlocks controls, stale responses cannot launch terminals or reset newer operations, and pairing submits only once. Closing creation stops waiting; it does not undo a repository already created on GitHub.

Voice state checks also cover explicit sending versus recognition finalization, shared microphone ownership, terminal switching, draft retention on disconnect, immutable retries, late acknowledgements, and cancelled permission requests. On Vision Pro, verify long dictation across pauses, repeated sends, switching terminals, permission denial, background/sleep and reconnect, and stopping capture from Settings in both workspace modes. Simulator compilation does not validate microphone behavior or comfort.
