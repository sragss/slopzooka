# Ephemeral Pi → Codex CUA probe

This isolated experiment runs Pi's in-memory agent loop against the installed Codex computer-use MCP runtime. It does not automate the ChatGPT composer, create Codex tasks, or change SlopZooka's window/session architecture.

**November 9 result:** a live `gpt-6.1-sol` run used the native Mac tools to enter `pi-direct`, increment our disposable app twice, inspect its state and return a screenshot to the model. Both the fixture state file and screenshot confirm the result. Direct Chrome initialization still fails with `Cannot verify browser access without the current turn`. See the [findings and evidence](../../.plans/2026-11-09-pi-cua-probe.md).

The [Opus follow-up](../../.plans/2026-11-09-claude-cua-compatibility.md) also passes the native task with `claude-opus-5-5` using the same adapter. It records current pricing, actual token usage, a transient native capture failure during the GPT comparison, and the remaining runtime contract.

## Run

Requires Node 22.20+ and the locally installed ChatGPT/Codex runtime for native/browser checks. This experiment has its own pinned dependencies; run from this directory:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test

# Live model + synthetic image fixture; no desktop control.
node cli.mjs --target fixture --key-file /path/to/local.env

# Same model/tool loop with Claude Opus 5.5.
node cli.mjs --provider anthropic --target fixture --key-file /path/to/local.env

# No API credential needed; tests independent Chrome provisioning only.
node cli.mjs --target browser --check

# Same Chrome check selected by a live model.
node cli.mjs --target browser --key-file /path/to/local.env
```

The key file must contain `OPENAI_API_KEY` with Responses API access, or `ANTHROPIC_API_KEY` for `--provider anthropic`. The CLI parses only the selected variable; it does not source the file or export its contents. Alternatively provide the selected variable in the launching shell. Never put the secret itself in command arguments. Defaults are `gpt-6.1-sol` for OpenAI and `claude-opus-5-5` for Anthropic; `--model` selects an explicit model in that provider's pinned Pi catalog. Both use low reasoning effort. Logs include token/cache usage and SDK-estimated costs, not billing receipts.

For a native run, first prepare and launch the [existing disposable native fixture](../codex-runtime-probe/README.md#fixture-and-independent-app-setup-used-in-discovery). It must start with counter 0 and empty input for the live action check. Example using the already built temporary app:

```sh
open -g -n \
  --env SLZ_CUA_FIXTURE_STATE=/tmp/slz-codex-runtime-fixture/pi-probe-state.json \
  '/tmp/slz-codex-runtime-fixture/Slz Runtime Fixture.app'

# Attach and read state, without a model request.
node cli.mjs --target computer --check --allow-fixture

# Model chooses native actions, then observes the result and screenshot.
node cli.mjs --target computer --allow-fixture --key-file /path/to/local.env
```

Do not launch duplicate instances. After a completed action run, restart only that owned fixture before repeating the counter-2 test. Its state file records its PID; verify the executable before terminating it. The CLI owns and closes its MCP child, not the fixture or shared Codex helper. Exit 0 means execution ended without reported errors; verify the fixture state and screenshot independently before calling the task successful.

`--allow-fixture` answers MCP app-access requests only when the connector is `computer-use` and the requested app is exactly `dev.slopzooka.codex-runtime-fixture`. All other requests are cancelled. This narrowly represents the user's authorization for our test app; it is not a production permission UI or an OS permission bypass. The native runtime must already have working macOS permissions.

After a successful native action run (counter 2 and `pi-direct`), `node check-lifecycle.mjs` performs a read-only two-client check: close A, verify B remains usable, then close B. This tests connection lifetime only, not simultaneous input or helper-crash isolation.

## Small interface

- `harness.mjs`: one `Agent`, one `McpClient`, allowlisted discovered tools, model-visible text/images/structured results, sequential calls and Stop. The caller supplies a model stream and permission policy.
- `runtime.mjs`: reads the manifest matching the installed app version and starts its genuine launcher. Keeps the runtime's trusted-service/preloader configuration. Excludes inherited model keys, task identity and browser-host pipe credentials.
- `cli.mjs`: fixed, disposable test tasks and ignored run summaries/screenshots under `build/`. `--check` bypasses only model inference; it still uses the same MCP adapter. SIGINT/SIGTERM stop the owned connection. A probe limit of eight tool calls bounds these fixtures.
- `fixture.mjs`: a synthetic image MCP server for isolating image/tool-loop behavior. It is explicitly not a browser or native-control implementation.

Tool descriptions, JSON schemas, initialization instructions and first-use guidance come from the installed runtime. They reach the model through Pi without embedding copied vendor documentation. Only `js` and `js_reset` are model tools; no shell, ChatGPT task creation or package-install tools are exposed. `turn_ended` browser lifecycle integration remains unimplemented because this independent browser connection never obtains a session.

On transport timeout or disconnect, the harness stops further dispatch on that connection. A missing response does not prove an input was not delivered. It does not retry uncertain actions. Stop aborts the Pi loop, rejects queued work and closes the owned MCP process through Pi's transport. It cannot undo input already delivered. Tests cover these adapter semantics, not native-helper interruption latency or another agent's simultaneous control.

## Scope

### Native lifecycle qualification follow-up

`node qualify-native.mjs` builds and signs an owned temporary fixture, checks three native close/relaunch cycles and closes an owned MCP connection during a bounded script. It uses no model API and leaves ChatGPT and its shared helper running. **Observation through an old app handle may itself reopen that app**; the qualifier records actual PIDs and independent state and cleans up those reopened fixtures. The fixture now has a plist-backed state path so Launch Services relaunch does not depend on its original environment.

`node cold-slot.mjs --approved-slot` is disruptive and is only for a user-approved quiet slot: it quits ChatGPT normally, stops its shared helper, runs `qualify-native.mjs --cold --helper-failure`, and reopens ChatGPT afterward. Never run it just to poll readiness or while unrelated desktop tasks need the helper. The `--cold` qualifier refuses to call the run cold if either process is already present. [Measured results and limits](../../.plans/2026-11-09-runtime-qualification-results.md).

No durable coordinator, voice layer, production dependencies, window registry or streaming transport is added here. Native startup with ChatGPT closed is now measured on this installation; shipping terms, fresh-permission production onboarding, real updates, locked use, exact-window ownership and delivery to Vision remain unqualified. The private Codex browser backend remains unprovisioned; the sibling owned-extension experiment provides the tested independent browser path. Keep window presentation in the existing `WindowGateway` and process ownership on the Mac.

Pinned sources: [Pi Agent](https://github.com/earendil-works/pi/blob/v1.4.0/packages/agent/README.md), [Pi MCP](https://github.com/earendil-works/pi/blob/v1.4.0/packages/mcp/README.md), [Pi AI](https://github.com/earendil-works/pi/blob/v1.4.0/packages/ai/README.md), [OpenAI tool calling](https://developers.openai.com/api/docs/guides/tools). All three Pi packages are pinned to `1.4.0` in this directory's lockfile.
