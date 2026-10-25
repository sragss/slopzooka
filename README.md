# SlopZooka

Spatial coding for Apple Vision Pro. Your Mac owns terminal processes and workspaces; the headset opens windows onto them. Frontends appear from local web servers, your existing Portless registry, or saved URLs.

## Mac menu-bar app

Build once on macOS with Node.js 22+, pnpm, and Xcode:

```sh
pnpm install
pnpm build:mac-app
```

Builds stage and verify a complete signed bundle before replacing the last good build. A failed compile leaves the previous app intact. Quit an app running directly from `build/mac-app` before rebuilding; the build refuses to overwrite a live app.

Move `build/mac-app/SlopZooka.app` to Applications and open it. It lives in the menu bar, with a pairing code, terminal/frontend counts, **Open Dashboard**, **View Logs**, and **Start at Login**. Pairing lives under **Pair Vision Pro**; login startup and logs live under **Settings**. It does not occupy the Dock. Login startup is opt-in through macOS's login-item service; if macOS requires approval, the app links to Login Items settings.

The app bundles Node, production dependencies (including native PTY support), and the compiled companion. Running it does not require the repo, pnpm, or an installed Node. Your project tools (`git`, `gh`, Codex, etc.) still need to be installed. The app loads your login-shell PATH with a bounded timeout so tools managed by nvm/mise/pnpm remain available when launched from Finder.

Closing the menu leaves sessions running. **Quit** confirms before ending active terminal sessions, then shuts down the owned companion. The private parent/child pipe also shuts down the host if the UI crashes. A companion crash triggers bounded restart attempts; terminal sessions cannot survive a host crash. A host that never finishes startup is stopped after 15 seconds, with force termination five seconds later if it ignores shutdown; the UI remains available to retry. A pre-existing companion on the same port is left alone: stop the Terminal-launched host before switching to the app. Pairing credentials remain in the same `~/.slopzooka` store.

The build is signed ad hoc for local use and targets the build machine's architecture. Distribution to other Macs still requires Developer ID signing/notarization. `pnpm test:mac-app` verifies the signed bundle, packaged static assets and PTY, private status channel, native-app startup, child teardown after a simulated UI crash, and force termination of a hung startup using an isolated home and port. It does not enable login startup or modify your live companion.

## Vision Pro and development

Open `apps/vision-client/SlopZooka/SlopZooka.xcodeproj` in Xcode and run the headset app. Bonjour discovers the companion. Enter the pairing code shown in the Mac app once; the headset saves its credential in Keychain. Manual host/IP entry remains available under More. A verified IP is never rewritten into an untested hostname.

The headset launcher separates **Terminals**, **Projects**, and **Frontends**, and remembers your last tab. Project search and the tool selector are visible together. Use **Mac connection** for pairing or a manual address. Terminal windows keep frontend and dictation controls visible; shell creation, details, and ending a session live under the actions menu.

For companion development, run `pnpm dev:companion` instead of the menu-bar app. This prints the pairing code in Terminal. Open `http://localhost:7777/dashboard` for the desktop dashboard and pair with the same code.

`pnpm dev:companion` intentionally does **not** restart on source changes. An opt-in `pnpm --filter @slz/mac-companion dev:watch` is available; each restart ends its sessions. Rebuild the Mac app after changing its bundled host or native code.

**Named dashboard:** When an installed Portless proxy is configured, the companion automatically registers `slopzooka.localhost` through `portless alias`. **Open Dashboard** checks that the named route reaches this companion, then redirects there; if Portless is absent, stopped, misconfigured, or the name belongs to another port, it opens the regular localhost dashboard. The companion keeps running on its own port and Bonjour continues to advertise the Mac’s LAN address for Vision Pro. `.localhost` is for browsers on the Mac.

The named URL follows the existing proxy: `https://slopzooka.localhost` on HTTPS port 443, or e.g. `https://slopzooka.localhost:1355` on a custom port. SlopZooka does not restart the shared proxy, change its port, install Portless, or alter certificate trust. The static alias remains available across companion restarts. If Safari cannot resolve a `.localhost` name, use Portless’s `hosts sync` setup or the direct localhost URL. Set `SLOPZOOKA_PORTLESS=0` to disable the dashboard alias. Pair the browser once at the new hostname; its cookies are separate from localhost.

Portless is optional. The registry adapter is tested against the Portless 0.14 schema; use the Node version required by your installed Portless when running Portless itself.

## Terminal lifecycle

- A workspace is a git worktree. Each workspace can have multiple independent terminal sessions.
- Opening a session attaches a viewer. Closing a window or losing the network detaches it without killing the process.
- Sessions reappear in the launcher after restarting the headset app. Reopening restores the current screen, including the alternate screen used by TUIs.
- **New Shell** adds a terminal to the same workspace. **End Session** explicitly stops the process and its current descendants. Ending an already exited session removes its retained screen.
- Sessions survive client disconnects, not companion/Mac restarts. Detached processes continue running until explicitly ended or the companion stops.
- One viewer controls keyboard input and terminal size. Additional viewers are read-only; control transfers when the controlling viewer detaches. Native dictation is an authenticated host command and is ordered with keyboard input.

The stream uses ordered cursors, a bounded replay buffer, and headless xterm screen checkpoints. Clients acknowledge output after rendering. Slow viewers receive a checkpoint when their replay history expires. The host bounds parser input with PTY pause/resume and bounds each viewer's outstanding output. Checkpoints retain 1,000 scrollback lines; they are not an archival transcript. The terminal serializer is experimental, so unusual terminal extensions still need device validation.

Dictation carries a command ID. A retried request is deduplicated within the most recent 1,000 input commands for that session. IDs cannot be reused with different text.

## Frontends

Start your app normally (`next dev`, Vite, Python, or another HTTP server). The Mac companion inspects TCP listeners owned by your user and makes bounded HEAD requests to find web servers on arbitrary ports. It does not scan a list of guessed ports or require binding your app to the LAN. The launcher and terminal frontend panel update automatically.

There is one list and one Open action for three sources:

- **Local servers:** HTTP listeners appear after their first response, labeled with their working directory (or process name) and port. An existing app shows “Waiting for response” while its listener is unresponsive and “Stopped” for up to one minute after its listener disappears. Any HTTP response establishes availability, not application health. Discovery excludes the companion itself and known Portless proxy/backend ports, and deduplicates IPv4/IPv6 listeners owned by the same process. It checks at most 128 listeners, eight at a time, with an 800 ms probe deadline. No workspace ownership is inferred from a directory label.
- **Portless:** Keep using your usual workflow. SlopZooka reads `routes.json` and the proxy's port/TLS/LAN state from `PORTLESS_STATE_DIR` or `~/.portless`. Named routes retain their identity across backend port changes. Registration is not a health check. The adapter never starts, stops, reconfigures, or writes Portless state.
- **Saved URLs:** Use **Add URL** on the headset or host page for custom URLs, HTTPS servers, and deployed previews. Local addresses use the Mac gateway; remote URLs open directly on the headset, preserving their origin and path. Saved URLs persist in `SLOPZOOKA_HOME/frontends.json`; remove them with the headset's context menu or the host page's Remove button. Embedded credentials and non-HTTP(S) URLs are rejected. Local/remote classification happens when a URL is added; re-add it if its DNS destination changes between machines.

All local routes share one authenticated HTTP/WebSocket gateway implementation. Loopback-only servers remain reachable from the headset. Portless gateways forward through the existing proxy with the named Host header and verify HTTPS using Portless's CA. Ordinary local HTTPS URLs use Node's trusted CAs; private CAs must be trusted by Node (for example through `NODE_EXTRA_CA_CERTS`). There is no certificate-verification bypass. Automatic listener discovery currently detects HTTP; add HTTPS URLs explicitly.

Registered Portless `.local` frontends open directly when LAN mode is enabled. The headset must trust their certificate and the app must accept the LAN origin. Other remote/deployed URLs likewise use the headset's normal browser certificate validation.

The catalog prioritizes named Portless apps, saved URLs, and local project servers whose root responds with HTML or a redirect. JSON, unknown, and HTTP services without a detected project remain available under **Other services**. Local process working directories are matched to the nearest package or Git repository for project labels. Add a URL to keep an unusual app in the primary list. Exact saved/named URLs and discovered backend listeners are deduplicated.

Local preview gateways survive short server restarts (up to the 60-second discovery retention window), keeping their URL and cookie. Failure pages offer Reload and expandable upstream diagnostics; discovery warnings and gateway errors retain their original details in logs.

Gateway bootstrap preserves a saved URL's path, query, and fragment. HTTP bodies stream without buffering and WebSocket upgrades pass through. A response-header timeout protects against stalled upstreams without imposing an idle timeout on established streams. Repeated/concurrent opens reuse the listener. Preview reload keeps its WebView, cookies, and navigation history; frontend failures do not block terminal-list recovery.

Gateways preserve normal application Authorization headers, remove SlopZooka credentials before forwarding, translate same-origin redirects/CORS responses, and isolate frontend cookie stores in the native app. They do not rewrite JavaScript, absolute cross-service URLs, OAuth callbacks, or Secure cookie semantics. Apps requiring those features should use native LAN routing with appropriate origins and certificate trust. Local HTTP gateways are intended for a trusted development network, not internet exposure.

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

Shutdown closes admission before waiting for managed processes and frontend sockets; delayed launches cannot create new sessions during teardown.

Pairing credentials are hashed in a mode-600 host store. HTTP control endpoints require authentication; browser requests and WebSocket upgrades also enforce the companion origin. Pairing codes rotate on host restart, while paired credentials persist. The named dashboard supports Portless HTTPS with Secure cookies and exact-origin validation limited to the registered hostname through a loopback proxy. Direct LAN control transport remains HTTP; pairing is an access boundary, not transport encryption. Do not publish the control port to the internet.

Workspace mutations are serialized within the companion and the index is replaced atomically. Run one companion per `SLOPZOOKA_HOME`. Existing indexes with `clusterId` are read and migrated to `workspaceId` on the next mutation. An explicit nonexistent branch now fails instead of silently selecting a different branch. Defaults follow the repository's default branch.

## Code boundaries

- `apps/mac-menu`: native SwiftUI menu-bar UI, child-process supervision, login item, and vector icon.
- `scripts/build-mac-app.mjs`: self-contained, locally signed macOS application bundle.

- `src/server.ts`: HTTP routes, authenticated WebSocket transport, discovery, and shutdown.
- `src/sessions.ts`: PTY ownership, screen state, attachment, replay, resize ownership, and input deduplication.
- `src/dashboard-address.ts`: optional Portless dashboard alias, verified redirects, and localhost fallback.
- `src/frontend-discovery.ts`: read-only Portless adapter, macOS listener inventory, and bounded HTTP probes.
- `src/frontends.ts`: unified catalog, saved URLs, and frontend gateway lifecycle.
- `src/workspace.ts`: git worktrees and workspace persistence.
- `src/terminal-connection.ts`: browser reconnect and ordered rendering.
- `packages/protocol`: versioned terminal messages and runtime validation.
- Vision client: `HostConnection`, `CompanionAPI`, `LauncherState`, and `TerminalSessionController` separate connection identity, requests, launcher state, and the WebView bridge from presentation.

## Verify

```sh
pnpm typecheck
pnpm test
pnpm format:check
pnpm build:harness
xcodebuild -project apps/vision-client/SlopZooka/SlopZooka.xcodeproj \
  -scheme SlopZooka -sdk xrsimulator -configuration Debug \
  -derivedDataPath /tmp/slz-derived CODE_SIGNING_ALLOWED=NO build
```

Integration tests use temporary homes, real PTYs, and isolated HTTP/HTTPS/WebSocket fixtures. They do not modify your Portless registry, workspaces, or GitHub repositories. Tests cover authentication, malformed messages, reconnect/replay/checkpoints, output floods, multiple viewers, command deduplication, descendant cleanup, simultaneous workspace mutations, branch selection, and frontend listener lifecycle. Discovery tests include restart recovery with stable preview credentials, cancellation during shutdown, browser/service classification, project naming, a real macOS child server, non-HTTP exclusion, incremental SSE, WebSockets, Portless failure isolation, and saved-URL persistence. The TLS fixture requires `openssl`.

Before relying on a headset release, exercise these on physical Vision Pro: pair; open an agent and a shell in one workspace; close/reopen a window; sleep/wake the headset during output; dictate once while interrupting the connection; and open Next.js/Vite apps with HMR, auth, and cross-service requests. LAN certificate trust and framework origin policies require real-device verification.
