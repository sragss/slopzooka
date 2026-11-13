# Mac companion

[Back to README](../README.md) · [Development](../CONTRIBUTING.md)

## Build and install

Build on macOS with Node.js 22+, pnpm 10.28.0, and Xcode with visionOS support.
The Mac build needs an Apple Development or Developer ID signing identity; see
[signing options](#signing-and-distribution) for local test builds.

```sh
pnpm install
pnpm build:mac-app
```

Install your preferred agent CLI on the Mac. For GitHub repository browsing, run
`gh auth login` or set `GITHUB_TOKEN` / `GH_TOKEN`.

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
| `SLOPZOOKA_CODEX_COMMAND` / `SLOPZOOKA_CLAUDE_COMMAND` / `SLOPZOOKA_OPENCODE_COMMAND` | Explicit agent command overrides                                              |
| `PORTLESS_STATE_DIR`                                                                  | Portless instance to discover                                                 |

Agent commands use their normal permission behavior.

## Codex threads

The headset's **Projects → Codex threads** reads the latest 25 saved threads
through the installed Codex CLI's app-server interface, using the same login-shell
command as terminal launches (`SLOPZOOKA_CODEX_COMMAND`, or `codex`). Codex owns its
history under `CODEX_HOME` (normally `~/.codex`); SlopZooka does not parse its
database or transcripts. Update Codex if the catalog reports it is unavailable.

Resume requires an updated session service. If prompted, use **Restart Session
Service** when ready to end its existing terminals; updating the HTTP companion
alone preserves the older service. Thread titles and conversation contents are
not written to SlopZooka diagnostics.

## Diagnostics

**Settings → View Logs** opens `SLOPZOOKA_HOME/logs` (default
`~/.slopzooka/logs`). Each home owns its logs; use a separate `SLOPZOOKA_HOME` for
development or another isolated instance. The former `SLOPZOOKA_LOG_DIR` override
is no longer used.

Companion, session-service, and menu logs use separate rotating JSONL files in
that directory. Vision Pro and browser events are collected into the companion’s
files, preserving their source timestamps, sequence numbers, and correlation IDs.
Native window, persistence, voice, and WebView activity joins HTTP, terminal
transport, process lifecycle, and periodic traffic summaries. Terminal text,
dictation transcripts, request bodies, and credentials are excluded by default.

The live structured-log budget is 256 MiB: 128 MiB for the companion and collected clients,
112 MiB for the session service, and 16 MiB for the menu. Writers rotate at 4 MiB
or 15 minutes. Writers start fresh segments after startup or a write failure,
leaving previous crash tails intact for capture. They reserve capacity for a
whole segment and prune only when opening one, with a 512-segment bound per role.
The menu uses a serial file actor and appends to uniquely named segments. Retention targets 24 hours;
heavy activity can shorten it. Queues and individual events are also bounded.
`SLOPZOOKA_LOG_LEVEL=debug` enables successful HTTP-read diagnostics in the
companion. These logs are local; there is no automatic external upload.

### Investigating terminal lag

Terminal browsers emit `latency.summary` about every ten seconds during activity,
and once when detached. Measurements contain counts and durations, never keys or
terminal text. Match `sessionId`, `connectionId`, and `serviceInstanceId` with the
session service's `traffic.summary` and transport events around the incident time.

| Measurement | What a high value points toward |
| --- | --- |
| `eventDispatchMaxMs`, `eventToSendMaxMs` | WebKit event delivery or local input handling |
| `inputAckMaxMs`, `inputAckTimeouts` | The round trip from browser input submission through the native route and companion relay to the session service's PTY write submission |
| `queueWaitMaxMs`, `queuedFramesMax`, `queuedCharactersMax` | Output waiting in the browser before xterm parsing |
| `parseMaxMs`, `parseToRenderMaxMs` | Browser parser work or the wait from parsed output to xterm's render event |
| `eventLoopDelayMaxMs` | Browser timer delay while the document is visible |
| Service `parserMaxMs`, `parserPendingMs`, `pauseMaxMs` | Headless parser backlog and PTY output backpressure on the Mac |
| Service `checkpointMaxMs`, `checkpoints`, `cols`, `rows` | Expensive screen serialization or repeated resizing/checkpoint recovery |
| Service `event-loop.summary` | Scheduling stalls in the Node session-service process |
| Companion `event-loop.summary` | Scheduling stalls in the HTTP/WebSocket relay process |

Input receipts sample at most once per second, with one outstanding probe and a
ten-second timeout. They bypass the browser's output queue and require a service
advertising `supportsInputAck`; retained older services still work but provide no
receipts. A receipt confirms submission to node-pty, not that the foreground app
read or echoed the input. All durations use local monotonic clocks, so no clock
synchronization is needed. Maxima describe the summary interval, not percentiles.
The Node event-loop monitor samples at 20 ms; its normal floor is about 20 ms.

For a useful device reproduction, note the time, connection method, whether you
are using Mac Virtual Display keyboard sharing or a directly connected keyboard,
and whether the terminal is idle or producing output. Repeat in a fresh shell
and a busy agent terminal, then capture the incident from the affected Mac.
Keyboard-sharing delay before WebKit creates/delivers the event, foreground app
processing, and physical display/compositor latency still require device checks;
these timings do not claim to measure key-to-photon latency. Network disconnects
appear separately as route failures and terminal retries.

Output has both byte and frame limits. The browser combines consecutive queued
output into bounded parser batches; checkpoint and control messages preserve their
ordering. Each viewer has at most 256 unacknowledged frames and replay retains at
most 4,096 frames or 512 KiB. A lagging viewer whose replay expires gets the current
screen checkpoint while other viewers and the existing process continue.

Browser changes require rebuilt assets and **Reload Content**. New service-side
timings and frame limits require an updated session service. The service survives
companion restarts: an explicit session-service restart ends its sessions, so save
work first. See [development reload behavior](../CONTRIBUTING.md#run-the-companion).

Paired clients can use these endpoints for debugging and future report tooling:

| Endpoint | Purpose |
| --- | --- |
| `POST /api/diagnostics/events` | Internal versioned batch intake for clients |
| `GET /api/diagnostics/reports/:id` | Download a captured incident as self-contained JSON |
| `POST /api/diagnostics/capture` | Capture retained evidence and return its manifest/download path |

Capture accepts an optional `around` UTC ISO timestamp as an incident bookmark.
It preserves retained events without filtering, sorting, or deduplicating them;
time filtering belongs to future bug-report tooling, which can interpret source
clocks and retry identities. From a paired
dashboard’s browser console:

```js
const report = await fetch("/api/diagnostics/capture", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ around: new Date().toISOString() }),
}).then((response) => response.json());
location.href = report.download;
```

Each JSON artifact is bounded to 32 MiB, favoring recently written segments when
full. It includes raw events and a manifest of producer/build/runtime identities,
missing builds or role coverage, truncation, damaged segments, storage loss
counters, and incomplete Mac flushes. Build identity travels with each event, so
it survives startup-record rotation. Original timestamps remain intact; buffered
client events acquire the latest clock observation at upload. Its observation
time and uncertainty remain explicit; a later observation cannot establish whether
a device’s clock changed earlier.

Captures persist under `reports` with separate limits of 64 MiB, 128 reports, and
seven days, pruned on capture. Save the download when filing a bug: a timestamp
alone cannot recover logs after rotation or a report after eviction. No report is
sent externally automatically.

A preloaded fatal-error handler retains the latest uncaught bootstrap failure in
`bootstrap.jsonl` for each Node role, independently of structured logger startup.
Each fallback is at most 8 KiB plus a newline and uses no inherited log descriptor.
It covers application-import failures; errors before Node can run its preload and
raw third-party stderr are not captured. The Mac menu also records launch failures.

Delivery is best effort. The headset retains up to 8 MiB in memory during an
outage; standalone browser documents retain up to 256 KiB. Successful authenticated
uploads acknowledge only the submitted identities. Buffer overflow is reported in
subsequent events. Reloading a standalone tab or restarting the headset loses
unsent events; suspension delays uploads. Forced termination or power loss can lose
a recent write. Captures include already collected client events, not unreachable
clients’ pending buffers. They do not capture arbitrary preview applications’
internal logs.

Updating the companion leaves existing terminal processes running. A retained
older session service keeps its legacy `session-service.log` and reports an
incomplete diagnostic flush. Previously launched services keep their original
log path, including any former override, and mark capture incomplete when that
path is outside the current home’s logs. **View Logs** identifies the actual path.
Use the existing explicit session-service restart
when ready to end those sessions and enable its new writer. Historical unbounded
log files are not rewritten or deleted automatically.

## Bug reports

Choose **Report a bug** in the dashboard or **Settings → Report a Bug…** in the
Mac menu. The report page saves a diagnostic snapshot on this Mac and lets you
describe the problem. **Review on GitHub** opens a draft in `sragss/slopzooka`
using your browser’s GitHub login; submit it there when ready. GitHub CLI login
is not required for this desktop browser flow. The headset instead opens a native
voice composer, then shows the public preview and GitHub account before **Create
Public Issue**. It uses the companion’s existing `GITHUB_TOKEN` / `GH_TOKEN` or
`gh auth token`; credentials stay on the Mac and go only to GitHub’s API. Missing
credentials fall back to the browser composer. See [headset reporting](vision-pro.md#diagnostics).

Issues are public. The public draft includes only your summary/description,
incident timestamp, local report ID, and a bounded list of build fingerprints and
runtime versions. Expand **Preview public report** to inspect exactly what will
be sent to GitHub. It contains no captured event bodies, file paths, host/client
identities, or private error details. What you type or dictate is included as written.

Logs stay local. **Download local snapshot** requires companion authentication
and downloads the full JSON for your own inspection; it does not attach or upload
it. Redacted diagnostics can still contain private paths, repository names, URLs,
and action history. Attachments on public GitHub issues are public too. Share a
snapshot only through a separately agreed access-controlled channel. Retention
and capture bounds are described above; a local report ID is not a remote
maintainer download link. Captures can omit still-buffered/offline client events.
Native captures are saved as `SLOPZOOKA_HOME/logs/reports/<report-id>.json` on the
Mac; their report ID appears in the public preview. Only authenticated companion
requests can download them through `/api/diagnostics/reports/<report-id>`.

Native public drafts expire after 30 minutes or a companion restart. **Review Again**
prepares a fresh review after expiry or an account/connection rejection, keeping
your report text. Preparing a review refreshes the Mac’s GitHub credentials. Before
creating an issue, the companion verifies the reviewed account and writes using
that same credential snapshot. Repeated requests for a submitted draft return its
cached outcome, even if the account has since changed. Timeouts and cancellation
never automatically retry a write; check existing issues after an ambiguous failure.

If capture or pairing fails, you can still review and submit the public issue
without logs. Use **Retry local snapshot** after reconnecting. The Mac menu can
also open GitHub directly when its companion is unavailable.

## Browser terminal control

One viewer controls a terminal's keyboard and size. Other views show **Read only**. Click **Take Control** in a browser terminal to move control to that tab; the previous viewer stays connected and becomes read-only. This preserves the session and shell process, including when recovering after a companion restart. Closing the controlling view still transfers control automatically.

The button is hidden on Vision Pro. It requires an updated session service; updating the companion alone leaves older services and their sessions running. Use the Mac menu's explicit session-service restart when ready to end those sessions and load the new runtime.

## Shutdown and launch retries

HTTP companion shutdown closes public admission, viewer connections, and frontend gateways without stopping terminal ownership. Session-service shutdown closes its own admission before terminating session descendants. An in-flight launch may have succeeded even if an HTTP reply was lost; retry with the same session ID instead of launching another agent.

## Authentication and network access

The companion registers its `_slopzooka._tcp` service through macOS's built-in DNS-SD service. macOS owns the hostname and network address records; SlopZooka does not publish competing host records or rename the Mac. The registration ends when the HTTP companion exits, including after a crash. Restarting discovery does not restart the session service.

Opening the dashboard from the menu uses a single-use sign-in link, issued through the private app/companion pipe and valid for 60 seconds at the selected dashboard origin. The browser removes the link's fragment and exchanges it for an HttpOnly session cookie; the PIN and reusable credentials are never placed in the URL.

Pairing credentials are hashed in a mode-600 host store. HTTP control endpoints require authentication; browser requests and WebSocket upgrades also enforce the companion origin. Connection codes contain six digits, expire after five minutes, and rotate on host restart. Pairing is limited to ten attempts per minute across the host; paired credentials persist.

The named dashboard supports Portless HTTPS with Secure cookies and exact-origin validation limited to the registered hostname through a loopback proxy. Direct LAN control transport remains HTTP; pairing is an access boundary, not transport encryption. Do not publish the control port to the internet.

## Workspace storage

Workspace mutations are serialized within the companion and the index is replaced atomically. Run one companion per `SLOPZOOKA_HOME`. Legacy indexes with `clusterId` migrate to `workspaceId` on the next mutation. An explicit nonexistent branch fails. Defaults follow the repository's default branch.
