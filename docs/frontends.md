# Frontends

[Back to README](../README.md) · [Host configuration](mac-companion.md#host-configuration)

Start your app normally (`next dev`, Vite, Python, or another HTTP server). The Mac companion inspects TCP listeners owned by your user and makes bounded HEAD requests to find web servers on arbitrary ports. It does not scan a list of guessed ports or require binding your app to the LAN. The launcher and terminal frontend panel update automatically.

There is one list and one Open action for three sources:

- **Local servers:** HTTP listeners appear after their first response, labeled with their working directory (or process name) and port. An existing app shows “Waiting for response” while its listener is unresponsive and “Stopped” for up to one minute after its listener disappears. Any HTTP response establishes availability, not application health. Discovery excludes the companion itself and known Portless proxy/backend ports, and deduplicates IPv4/IPv6 listeners owned by the same process. It checks at most 128 listeners, eight at a time, with an 800 ms probe deadline. Workspace ownership uses the canonical listener directory and exact worktree boundaries, independently of the display label.
- **Portless:** Keep using your usual workflow. SlopZooka reads `routes.json` and the proxy's port/TLS/LAN state from `PORTLESS_STATE_DIR` or `~/.portless`. Named routes retain their identity across backend port changes. Registration is not a health check. The adapter never starts, stops, reconfigures, or writes Portless state.
- **Saved URLs:** Use **Add URL** on the headset or host page for custom URLs, HTTPS servers, and deployed previews. Local addresses use the Mac gateway; remote URLs open directly on the headset, preserving their origin and path. Saved URLs persist in `SLOPZOOKA_HOME/frontends.json`; remove them with the headset's context menu or the host page's Remove button. Embedded credentials and non-HTTP(S) URLs are rejected. Local/remote classification happens when a URL is added; re-add it if its DNS destination changes between machines.

In a headset preview window, use **Back** and **Forward** beside Reload to move through that window's browsing history. Each button is disabled when there is no page in that direction. Reload keeps the current WebView and its history; closing the window or restarting the headset app starts a fresh history.

Web previews currently require **Local Network** in the headset's **Settings → Connected Mac**. With **Direct to Mac (Experimental)** selected, the catalog keeps previews visible but disables Open with an explanation; the Mac API enforces the same limitation before creating a gateway. Switching methods preserves the preview's window record, and returning to Local Network reloads it unless it was closed. Saved URLs can still be removed while unavailable. Streamed native previews are a later feature.

## Workspace configuration

Servers inside a managed worktree automatically appear beside that workspace and its terminals. This works with ordinary HTTP servers and Portless; no config or special launch command is required. Nested packages belong to their containing worktree, and simultaneous worktrees remain separate. The host dashboard offers an Open app button or a frontend picker; Vision Pro terminals show a workspace-only frontend popover. Apps without an identifiable workspace remain available in the global Frontends tab.

For explicit names and a preferred frontend, commit `.slopzooka.json` at the worktree root:

```json
{
  "version": 1,
  "frontends": [
    {
      "id": "web",
      "name": "Website",
      "directory": "apps/web",
      "default": true
    },
    { "id": "admin", "name": "Admin", "directory": "apps/admin" }
  ]
}
```

The file is optional. Missing `frontends` means automatic discovery; `"frontends": []` explicitly disables workspace frontend controls. `directory` defaults to `"."`, `name` defaults to `id`, and at most one entry can be the default (sorted first). Directories must stay inside the worktree, including symlink targets. The most specific matching directory supplies the label. Extra discovered servers remain accessible globally. Ambiguous directory/endpoint matches retain their URLs and produce a diagnostic instead of silently selecting a winner. Configuration errors include the file path and original reason, while automatic discovery continues. Changes take effect on the next catalog refresh.

Configuration describes browser surfaces, not running processes: it never launches a server or displays an invented startup state. Your agent or shell still runs the project's usual dev command. This initial schema intentionally contains only frontend hints; command orchestration and runtime registration are not part of it. Processes without a discoverable directory, remote previews, and containers may remain unassigned. Multiple surfaces sharing a directory or process can still be opened through the global catalog / Add URL; directory hints cannot distinguish their roles. No repository-name or port-number-only ownership guesses are made. Changing a route's workspace invalidates its existing preview gateway.

## Local gateways and HTTPS

All local routes share one authenticated HTTP(S)/WebSocket gateway implementation. Loopback-only servers remain reachable from the headset. HTTPS apps stay HTTPS between the Mac and headset, preserving Secure and HttpOnly login cookies and secure WebSockets. The companion generates a private preview CA under `SLOPZOOKA_HOME/preview-tls` using `openssl`; private keys are stored with owner-only permissions. The authenticated open response supplies the public CA to the headset, which validates the certificate chain, hostname, and expiry only at that preview's exact host and port. This does not install a system CA or change trust for external navigation. Pairing and the control API still require a trusted local network. Update both apps to use HTTPS previews; the new headset client rejects an older companion's HTTP downgrade. The Mac dashboard opens HTTPS apps at their original address, using the browser's existing trust.

Portless gateways forward through the existing proxy with the named Host header and verify upstream HTTPS using Portless's CA. Ordinary local HTTPS URLs use Node's trusted CAs; private CAs must be trusted by Node (for example through `NODE_EXTRA_CA_CERTS`). There is no certificate-verification bypass. Automatic listener discovery currently detects HTTP; add HTTPS URLs explicitly.

Registered Portless `.local` frontends open directly when LAN mode is enabled. The headset must trust their certificate and the app must accept the LAN origin. Other remote/deployed URLs likewise use the headset's normal browser certificate validation.

## Catalog and gateway lifecycle

The catalog prioritizes named Portless apps, saved URLs, and local project servers whose root responds with HTML or a redirect. JSON, unknown, and HTTP services without a detected project remain available under **Other services**. Local process working directories are matched to the nearest package or Git repository for project labels. Add a URL to keep an unusual app in the primary list. Exact saved/named URLs and discovered backend listeners are deduplicated.

Local preview gateways survive short server restarts (up to the 60-second discovery retention window), keeping their URL and cookie. Failure pages offer Reload and expandable upstream diagnostics; discovery warnings and gateway errors retain their original details in logs.

Gateway bootstrap preserves a saved URL's path, query, and fragment. HTTP bodies stream without buffering and WebSocket upgrades pass through. A response-header timeout protects against stalled upstreams without imposing an idle timeout on established streams. Repeated/concurrent opens reuse the listener. Preview reload keeps its WebView, cookies, and navigation history; frontend failures do not block terminal-list recovery.

Gateways preserve normal application Authorization headers and cookie security flags, remove SlopZooka credentials before forwarding, translate same-origin redirects/CORS responses and request origins/referrers, and isolate frontend cookie stores in the native app. They do not rewrite JavaScript, absolute cross-service URLs, or OAuth callback URLs embedded inside third-party redirects. Apps requiring those features should use native LAN routing with appropriate origins and certificate trust. Local gateways are intended for a trusted development network, not internet exposure.

Discovery sources fail independently: invalid Portless state produces a warning and preserves its last valid routes without preventing ordinary local servers or saved URLs from opening. Configuration changes are validated before commit; opens, refreshes, saved-URL mutations, and shutdown share one serialized lifecycle. Disappearing/stopped routes close their listeners and upgraded sockets. Changes to a route's upstream or transport invalidate only that route's gateway; reopen the frontend to obtain its replacement URL. A missing Portless installation is normal and produces no warning.
