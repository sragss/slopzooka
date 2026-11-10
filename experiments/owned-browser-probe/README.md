# Owned Chrome extension probe

An isolated implementation of the [owned-extension proposal](../../.plans/2026-11-09-runtime-integration-contract.md#an-owned-chrome-extension-is-a-bounded-alternative). Uses public Chrome APIs and our own source. No Codex browser runtime, private authorization context, copied vendor helper, Chromium fork, or production app changes.

See [findings and test journal](../../.plans/2026-11-09-owned-browser-extension-probe.md) for measured results and limits.

## Run

From this directory, with Node 22+ on macOS:

```sh
npm ci
node node_modules/playwright-core/cli.js install chromium
npm test
npm run probe
npm run probe -- --headed
```

The test creates an empty Chrome for Testing profile, a generated unpacked extension, a loopback fixture server and a native-messaging host registered **inside that temporary profile**. Chrome launches the real native host. It is not a mock of `chrome.debugger`. All runtime files live in a private temporary directory; no native-host registration or extension installation is made in your normal Chrome profile. Cleanup closes only the owned browser and removes that directory. Logs and disposable screenshots stay in ignored `build/run-*`.

`--headed` briefly opens a visible test browser. A separate test-only CDP connection simulates typing into the foreground fixture; agents control background tabs solely through the extension. This verifies concurrent synthetic input and observed focus, not a human usability study. The debugging port exists for fixture inspection only; the agent transport does not use it. Playwright supplies the test browser executable, not the agent's browser actions.

For the optional two-model test, install the sibling Pi harness dependencies once (`npm ci --prefix ../pi-cua-probe`), then:

```sh
node probe.mjs --headed --models --key-file /absolute/path/to/local.env
```

The file must contain working `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` values. Only those entries are read in memory, never sourced or passed to the browser, native host or MCP child. This spends API credits. The pinned Pi catalog supplies `gpt-6.1-sol` and `claude-opus-5-5`; these are the models qualified in this experiment, not an automatic model-selection policy. Both agents run concurrently through the existing `pi-cua-probe/harness.mjs` and separate MCP processes.

To expose a temporary endpoint for a terminal agent or another Pi loop:

```sh
node probe.mjs --headed --serve
```

The command prints a JSON `serve-ready` record with the permitted fixture origin, artifact directory and exact MCP `command`/`args`. Configure that stdio server for the test session. Open any path under the printed fixture origin; other origins are rejected. Ctrl-C cleans up. This does not change your global agent configuration.

The [actual terminal qualification](../../.plans/2026-11-09-runtime-qualification-results.md) now passes a real `codex exec` task alongside Pi, normal CLI cleanup, CLI interruption and peer continuation:

```sh
node terminal-qualification.mjs --codex /absolute/path/to/codex --key-file /absolute/path/to/local.env
```

This opens a visible disposable browser and spends normal Codex/API usage. Pin the executable: this machine had two different CLI versions on different PATHs. The runner gives only this fixture-origin-restricted MCP server per-invocation tool approval, retains read-only filesystem sandboxing, and leaves personal configuration unchanged. It does not qualify the final interactive xterm input/Stop UI.

## Boundary and tools

```text
Pi / terminal MCP client
  -> mcp.mjs (one private socket connection = one owner)
  -> bridge.mjs (transient routing, timeout/disconnect propagation)
  -> Chrome-launched native-host.mjs (bounded stdio/native framing)
  -> extension/worker.js (exclusive tab leases, queues, AX refs, CDP)
  -> Chrome tab
```

The extension is the single owner of target leases and input queues. Putting revocation beside the CDP transport lets Stop invalidate queued commands before awaiting detach. The bridge assigns caller identities; model arguments cannot choose another owner. This is a prototype companion adapter, not a second workspace/session/window manager. Production integration should retain the existing Mac process ownership and Vision `WindowGateway` boundary.

| Tool                               | Result                                                                      |
| ---------------------------------- | --------------------------------------------------------------------------- |
| `browser_tabs`                     | Scoped tab inventory, active flag and claim state                           |
| `browser_open` / `browser_claim`   | Exclusive opaque target for this MCP connection                             |
| `browser_observe`                  | Main-document AX roles, names, values and fresh element refs                |
| `browser_fill` / `browser_click`   | Tab-local input, with origin, ownership, revision and click hit-test checks |
| `browser_navigate`                 | Permitted-origin navigation; old refs expire                                |
| `browser_screenshot`               | Actual viewport JPEG as MCP image content                                   |
| `browser_release` / `browser_stop` | Revoke queued work without closing the tab                                  |

`browser_stop` permanently stops the current client identity. Reconnect a new MCP client to resume. A bridge reconnect restores transport but never restores targets or replays mutations. Reclaim and inspect the actual page. Input already dispatched is not reversible; a transport failure reports uncertain effects.

Stop is scoped to one caller. Failure or timeout of the shared native channel revokes every lease on that channel; the prototype favors a clear unavailable state over continuing after uncertain delivery. Per-target failure containment would need separate qualification before promising it.

The extension toolbar badge/title identifies a controlled tab; its action button releases that tab for human takeover. The button's real physical interaction remains a manual acceptance check. The automated Stop path has actual in-flight/queued-input coverage.

## Deliberate limits

- Only the disposable origin is admitted. The extension has powerful debugger permission; this is not production permission/onboarding code.
- The private socket directory and native-host token isolate this local experiment. They are not isolation from hostile processes running as the same macOS user. Shipping needs the companion's actual caller-admission policy.
- Main-document controls only. Cross-origin frames, popups, downloads, file choosers, native dialogs, complex editable widgets, key chords and arbitrary JavaScript tools are not implemented.
- Focus emulation is necessary for the measured headed background-click behavior. It changes what the page perceives as active, so renderer throttling and resource consumption need separate measurement.
- Click hit testing and ref invalidation reduce stale actions; they cannot make a changing DOM and multiple CDP requests transactional.
- No signed-in profile, stable-channel Chrome installation, lock/sleep, long-session reliability, human takeover usability or stream-to-Vision result is established here. Screenshots are model observations, not the continuous video path.
- The worker reconnect delay is fixed for this disposable test. A shipped integration needs bounded/backoff recovery, update handling and diagnostics. No automatic mutation retry should be added.

The probe's source, package lock and redacted evidence are committed. Generated extension configuration, browser profiles, native-host tokens, API credentials and images are not.


## Continuous background stream trial

`node probe.mjs --streaming --headed` runs the two-source Mac preflight with independent TLS receivers; add `--serve` to keep the fixture streams available for Vision. See the [live runbook](../surface-live-probe/README.md) for viewer/agent setup and cleanup. Frames are event-driven CDP JPEGs; background screenshots alone are not the acceptance criterion. Browser lease release currently ends its stream as well as input. This remains a disposable Chrome for Testing profile, not normal Chrome installation qualification.
