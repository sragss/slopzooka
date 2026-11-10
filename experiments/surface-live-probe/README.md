# Live surface experiments

Runnable preparation for [simulator/gateway](../../.plans/2026-11-09-simulator-gateway-live-plan.md) and [background browser streams](../../.plans/2026-11-09-background-browser-streaming-live-plan.md). The Mac tests are separate from physical-headset acceptance. This is opt-in test code, not a production orchestrator.

## Prepare once

Use the repository's existing dependencies and the pinned experiment packages:

```sh
npm ci --ignore-scripts --prefix experiments/surface-live-probe
npm ci --ignore-scripts --prefix experiments/owned-browser-probe
npm ci --ignore-scripts --prefix experiments/pi-cua-probe
```

The simulator uses the prepared fixture and WDA from `experiments/shared-window-probe`; its README documents their build. `prepare.mjs` builds signed device apps using an existing team and the already-generated probe Xcode project:

```sh
node experiments/surface-live-probe/prepare.mjs --team TEAM_ID
```

This builds the **actual SlopZooka source** under the separate `com.slopzooka.probe.gateway` identity, plus ProbeViewer. It does not install or launch them. `build/prepared/artifacts.json` records paths. During the agreed device slot, add `--install --device DEVICE_UUID` to install both. Gateway Probe has its own pairing, client ID and saved layouts; it does not establish restoration of the user's regular installation.

After installation, launch Gateway Probe with `node experiments/surface-live-probe/device.mjs --device DEVICE_UUID --app gateway`. It restarts only this test bundle. Connect it using the setup file described below.

Prefer adding `--host HOST:PORT` from the isolated companion's setup file. This preselects that address through the existing `companionHost` preference and avoids choosing the regular companion from an ambiguous discovery list. The user still approves local-network access and enters the pairing code. This launch-argument path was exercised in the physical session.

## Simulator and actual gateway

Choose the exact disposable device from `xcrun simctl list devices available`. The runner admits only a device whose name contains `probe`, refuses an already running driver on it, and never uses `booted` as a selector.

```sh
node experiments/surface-live-probe/simulator.mjs --udid UDID --prepare --smoke
node experiments/surface-live-probe/simulator.mjs --udid UDID --prepare --workspace WORKSPACE_ID
```

`--prepare` explicitly boots/installs/activates only this fixture. The smoke run checks device/app identity, an independently observed counter increment, source frames and Stop rejection, then cleans up. The live form prints `simulator-ready` and paths under a unique ignored run directory. It runs until SIGINT, without an overall cutoff. Per-call timeouts remain bounded.

Input and MJPEG share the owned WDA session/UDID and reserved ports. Accessibility presses can return without changing SwiftUI switches; `surface_tap` offers a fresh-image coordinate fallback, translates pixels to current device points, and rejects stale observations or viewport changes. The agent must verify effects. This is device-specific control, not qualification of the opaque native Mac runtime's window binding.

In another process, attach an isolated companion to that run's manifest:

```sh
node experiments/surface-live-probe/companion.mjs ABSOLUTE_RUN_PATH/surfaces.json
```

This launches the real companion with its own home/port, Portless disabled and `SLOPZOOKA_SURFACE_PROBE_MANIFEST` set. It creates private `headset-setup.json`, `companion-connection.json`, and `agent-config.json`. The setup file contains the LAN address and a short-lived pairing code. Connect **Gateway Probe** normally; allow local-network access if asked. No fake receiver is registered by the live runner. Workspace ID is an association to a prepared workspace, not a command to provision worktrees/PTYs.

Presentation commands travel through pairing-protected routes and the real `WindowGateway`. The existing layout/outbox still owns desired windows; scene actions remain in `WindowScene`. Stream URLs/tokens are resolved from the live manifest and never stored in window records. The test uses the existing catalog refresh cadence (roughly three seconds); request acceptance, scene presence and receiver status are reported separately. No active presenter yields a clear failure.

## Two background browser streams

```sh
node experiments/owned-browser-probe/probe.mjs --streaming --headed
node experiments/owned-browser-probe/probe.mjs --streaming --headed --serve
node experiments/owned-browser-probe/probe.mjs --streaming --headed --phases --stream-seconds 60
```

The first command runs Mac-only preflight and exits. The second keeps the isolated browser and pinned-TLS media host available, printing `stream-ready`. A/B are background tabs; C is the disposable human typing tab. Pixel frames use the same debugger target as input, with a bounded relay and independent local receivers. Current source: JPEG, quality 65, maximum 1280×960, every third source frame. This is an experimental source/transport measurement, not the final video codec.

The live run writes `viewer-connection.json`, `agent-a.json` and `agent-b.json`. Launch ProbeViewer with the connection contents in `SLZ_PROBE_CONNECTION` and `SLZ_PROBE_AUTO_OPEN=all`, using the existing device-launch script pattern, or paste the private connection into its UI. Do not print pairing/stream credentials in shared logs. A/B are clearly labeled by nonce.

The exact no-picker launch is `node experiments/surface-live-probe/device.mjs --device DEVICE_UUID --app viewer --connection RUN/viewer-connection.json`. It passes credentials in the child environment, not shell arguments. A successful launch is not a physical visibility verdict. `--phases` measures one animated source, two animated sources and two static sources separately; `--stream-seconds` sets each sample duration, without limiting a subsequent `--serve` session. Results include achieved cadence, JPEG payload, framed source-event bytes and independent receiver bytes. CPU/GPU/power attribution and deliberate cover/minimize remain separate measurements.

Closing an agent connection currently revokes that slot's debugger lease and ends its stream. For a visible result that stays open after a Pi turn, use `--hold` below. This temporary shared input/capture ownership is an explicit limitation; input Stop is not yet independent view-only retention for browser streams.

## Real agents, same tools

Put the bounded fixture task in a local prompt file. Pi consumes the same stdio MCP adapter used by terminal Codex:

```sh
node experiments/pi-cua-probe/live-agent.mjs --config RUN/agent-config.json --prompt-file PROMPT.txt --key-file EXISTING_ENV_FILE --hold
node experiments/surface-live-probe/terminal.mjs --codex EXPLICIT_CODEX_PATH --config RUN/agent-b.json --prompt-file PROMPT.txt
```

For browser Pi use `agent-a.json`. For simulator Pi use `agent-config.json`, rewritten by the companion launcher to include presentation tools. Before the companion is attached, it grants only device tools. The live simulator prompt can ask the agent to find the one active client with `surface_status`, present the prepared fixture, change its UI and verify. Do not claim headset visibility from an accepted command alone.

The terminal runner uses `codex exec`, its normal local authentication, an empty temporary cwd and per-invocation approval scoped to this disposable MCP. Shell/apps/plugins/web search are disabled and personal configuration is not edited. This does not test interactive xterm keyboard routing. Pi reads only the named API key from the supplied env file and never forwards it to the MCP child.

Prepared prompts are [simulator.txt](prompts/simulator.txt) and [browser.txt](prompts/browser.txt). They are bounded fixture tasks, not the unapproved product workflow catalog. Pi's local trace retains tool arguments/results with images in separate private files. Check fixture state independently of the model's final report.

Operator controls use the same boundary:

```sh
node experiments/surface-live-probe/control.mjs --config RUN/agent-config.json --action status
node experiments/surface-live-probe/control.mjs --config RUN/agent-config.json --action open --client EXACT_ACTIVE_CLIENT
node experiments/surface-live-probe/control.mjs --config RUN/agent-config.json --action close --client EXACT_ACTIVE_CLIENT
node experiments/surface-live-probe/control.mjs --config RUN/agent-config.json --action stop
node experiments/surface-live-probe/control.mjs --config RUN/agent-config.json --action resume
```

`status` exposes command receipts, scene presence and receiver state independently. `reload` is also available. Simulator Resume verifies identity and requires a fresh observation; browser Stop ends its lease and requires a new owned run. Presentation control requires the companion. No model receives Resume automatically.

## Stop, logs and limits

Stop agent callers, then the companion runner, then the simulator/browser host with SIGINT. The companion stops only its isolated session service. Simulator cleanup deletes its Appium session, stops its own server and checks dedicated-device WDA children that may have reparented to launchd. A device booted by the run is shut down; an already booted device remains booted. Never kill a port's unrelated occupant.

Every run retains manifests, fixture events, screenshots, model/terminal results and cleanup records under ignored `build/`. Browser fixtures contain no personal data. Keep connection files and full UI/model traces local; publish only sanitized outcomes and hashes. Failures are retained, including the initial activation/parser setup failures and the switch press that had no effect.

Physical A1–A6/B1–B6, sustained performance, spatial placement, lock/sleep, clean permissions, arbitrary native apps, H.264 transcoding and final control ownership remain separate acceptance work. No automatic device lock or shared ChatGPT-helper restart is part of these runners.

See [physical results and remaining cases](../../.plans/2026-11-09-surface-live-results.md). Browser packet regression coverage now compiles and runs the actual ProbeViewer Swift parser; testing only the separate JavaScript receiver missed required header fields and caused black headset views in the first attempt.
