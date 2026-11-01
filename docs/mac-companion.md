# Mac companion

[Back to README](../README.md) · [Development](../CONTRIBUTING.md)

## Build and install

Build on macOS with Node.js 22+, pnpm 10.28.0, and Xcode:

```sh
pnpm install
pnpm build:mac-app
```

Builds stage and verify a complete signed bundle before replacing the last good build. A failed compile leaves the previous app intact. Quit an app running directly from `build/mac-app` before rebuilding; the build refuses to overwrite a live app.

Move `build/mac-app/SlopZooka.app` to Applications and open it. It lives in the menu bar, with a pairing code, terminal/frontend counts, **Open Dashboard**, **View Logs**, and **Start at Login**. The connection code is always visible for headset pairing; **Open Dashboard** signs your browser in automatically. Login startup and logs live under **Settings**. It does not occupy the Dock. Login startup is opt-in through macOS's login-item service; if macOS requires approval, the app links to Login Items settings.

The app bundles Node, production dependencies (including native PTY support), and the compiled companion. Running it does not require the repo, pnpm, or an installed Node. Your project tools (`git`, `gh`, Codex, etc.) still need to be installed. The app loads your login-shell PATH with a bounded timeout so tools managed by nvm/mise/pnpm remain available when launched from Finder.

## Session controls

Closing the menu or choosing **Quit** leaves terminal sessions and their processes running. The menu owns the HTTP companion; its private parent/child pipe stops that companion if the UI exits or crashes. A separate local session service owns the PTYs and screens, so reopening the menu or restarting the HTTP companion reconnects to the same sessions. **Settings → Restart Companion** is safe for running terminals. **Restart Session Service** and **End All Sessions and Stop Service** explicitly end sessions and their descendants after confirmation.

A companion crash triggers bounded restart attempts without restarting the session service. A host that never finishes startup is stopped after 15 seconds, with force termination five seconds later if it ignores shutdown; the UI remains available to retry. A pre-existing companion on the same port is left alone: stop the Terminal-launched host before switching to the app. Pairing credentials remain in the same `~/.slopzooka` store.

## Signing and distribution

The build uses an available Apple Development / Developer ID certificate so its signing identity survives updates and macOS can retain folder permissions. Set `SLOPZOOKA_SIGN_IDENTITY` to a specific identity when multiple teams are installed. Without a certificate, the build stops with setup guidance; `SLOPZOOKA_SIGN_IDENTITY=-` explicitly permits an ad-hoc test build, whose privacy permissions may reset after every rebuild. Run the app from Applications rather than from a repository inside Documents or Downloads. The bundle targets the build machine's architecture. Distribution to other Macs still requires Developer ID signing/notarization.

See [packaged-app verification](../CONTRIBUTING.md#verify) for build and supervision checks.

## Dashboard and Portless

When an installed Portless proxy is configured, the companion automatically registers `slopzooka.localhost` through `portless alias`. **Open Dashboard** checks that the named route reaches this companion, then redirects there; if Portless is absent, stopped, misconfigured, or the name belongs to another port, it opens the regular localhost dashboard. The companion keeps running on its own port and Bonjour continues to advertise the Mac’s LAN address for Vision Pro. `.localhost` is for browsers on the Mac.

The named URL follows the existing proxy: `https://slopzooka.localhost` on HTTPS port 443, or e.g. `https://slopzooka.localhost:1355` on a custom port. SlopZooka does not restart the shared proxy, change its port, install Portless, or alter certificate trust. The static alias remains available across companion restarts. If Safari cannot resolve a `.localhost` name, use Portless’s `hosts sync` setup or the direct localhost URL. Set `SLOPZOOKA_PORTLESS=0` to disable the dashboard alias. Opening from the menu signs the browser in at the selected hostname. Visiting a dashboard URL directly still requires pairing once per browser and hostname.

Portless is optional. The registry adapter is tested against the Portless 0.14 schema; use the Node version required by your installed Portless when running Portless itself.

## Host configuration

| Variable                                                                              | Purpose                                                                       |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `SLOPZOOKA_PORT`                                                                      | Companion port, default `7777`                                                |
| `SLOPZOOKA_PORTLESS`                                                                  | Set `0` to disable automatic dashboard alias registration and redirection     |
| `SLOPZOOKA_HOST`                                                                      | Bind address, default dual-stack `::`                                         |
| `SLOPZOOKA_HOME`                                                                      | Workspace index, clones, worktrees, and pairing store; default `~/.slopzooka` |
| `SLOPZOOKA_SIGN_IDENTITY`                                                             | Build signing identity; `-` opts into ad-hoc signing                          |
| `SLOPZOOKA_BUILD_DIR`                                                                 | Build output directory, default `build/mac-app`                               |
| `SLOPZOOKA_LOG_DIR`                                                                   | Override companion log directory                                              |
| `SLOPZOOKA_CODEX_COMMAND` / `SLOPZOOKA_CLAUDE_COMMAND` / `SLOPZOOKA_OPENCODE_COMMAND` | Explicit agent command overrides                                              |
| `PORTLESS_STATE_DIR`                                                                  | Portless instance to discover                                                 |

Agent commands use their normal permission behavior.

## Shutdown and launch retries

HTTP companion shutdown closes public admission, viewer connections, and frontend gateways without stopping terminal ownership. Session-service shutdown closes its own admission before terminating session descendants. An in-flight launch may have succeeded even if an HTTP reply was lost; retry with the same session ID instead of launching another agent.

## Authentication and network access

Opening the dashboard from the menu uses a single-use sign-in link, issued through the private app/companion pipe and valid for 60 seconds at the selected dashboard origin. The browser removes the link's fragment and exchanges it for an HttpOnly session cookie; the PIN and reusable credentials are never placed in the URL.

Pairing credentials are hashed in a mode-600 host store. HTTP control endpoints require authentication; browser requests and WebSocket upgrades also enforce the companion origin. Connection codes contain six digits, expire after five minutes, and rotate on host restart. Pairing is limited to ten attempts per minute across the host; paired credentials persist.

The named dashboard supports Portless HTTPS with Secure cookies and exact-origin validation limited to the registered hostname through a loopback proxy. Direct LAN control transport remains HTTP; pairing is an access boundary, not transport encryption. Do not publish the control port to the internet.

## Workspace storage

Workspace mutations are serialized within the companion and the index is replaced atomically. Run one companion per `SLOPZOOKA_HOME`. Legacy indexes with `clusterId` migrate to `workspaceId` on the next mutation. An explicit nonexistent branch fails. Defaults follow the repository's default branch.
