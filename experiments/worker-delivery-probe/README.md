# Existing Codex worker delivery probe

Opt-in Mac experiment for a real terminal Codex worker plus a separate structured controller. It uses the production `SessionServiceClient`/session service to own the PTY. Codex's normal TUI connects to one explicitly owned App Server over a private Unix socket; the controller joins that same runtime/thread. No production application source or existing terminal is changed.

This tests the **owned App Server + remote TUI launch arrangement**, not adoption of every arbitrarily launched Codex process. It retains the Codex agent loop and TUI. Only disposable MCP fixture tools are granted for the model tasks; shell, web search, apps and plugins are disabled. The bootstrap comes through the normal terminal input path; measured external tasks use the native control protocol.

## Run

From the repository root, after `pnpm install` and `npm --prefix experiments/surface-live-probe ci`:

```sh
apps/mac-companion/node_modules/.bin/tsx \
  experiments/worker-delivery-probe/probe.mts \
  /absolute/path/to/codex
```

The measured binary is Codex CLI 0.167.0. The experiment uses its experimental queue APIs and generated schemas; it is not a version-independent SDK. It requires the existing file-backed ChatGPT login in `~/.codex/auth.json`. The runner copies it into a private temporary Codex home, never prints it, and removes that copy during cleanup. It does not modify the user's normal config/auth or shared daemon. Inference uses that normal account, so this is a live model test rather than a unit test.

`--remaining` skips the already-measured idle/queue/steer section and runs CLI queue, uncertain delivery, interruption, elicitation and exit cases. The final recorded run uses the full sequence.

## Evidence

Each run creates an ignored private `build/run-*` directory with:

- native RPC requests, notifications and responses;
- terminal output from SlopZooka's actual PTY transport;
- an independent MCP effect ledger, including gate entry/release;
- the result classifications and cleanup outcome.

`completed: true` means the experiment completed its assertions. It does **not** mean native delivery is idempotent or every product requirement passed. In particular, duplicate queue submissions deliberately measure whether work repeats. Earlier run files used `passed` for this harness-completion flag; the result report interprets each observation separately.

The native queue runs the model's tasks. The controller does not implement another queue. The lost-reply fault discards one server response at the adapter boundary and disconnects; recovery queries the native queue/history without resubmitting. The permission case is harmless MCP form elicitation, not a macOS permission grant or a shell escalation. Stop measures native turn interruption plus the independent fixture effect; it does not establish cancellation of an already-dispatched desktop action.

The runner returns the TUI to its retained shell, then stops only its isolated session service and App Server. The original app, existing PTYs and normal Codex daemon are untouched. Private raw logs can contain account metadata and fixture prompts; commit only sanitized findings and artifact hashes.

Generate the matching interface files locally if inspecting a different binary:

```sh
/absolute/path/to/codex app-server generate-json-schema \
  --experimental --out experiments/worker-delivery-probe/build/schema
/absolute/path/to/codex app-server generate-json-schema \
  --out experiments/worker-delivery-probe/build/schema-stable
```

The [official App Server documentation](https://learn.chatgpt.com/docs/app-server) describes remote TUI attachment, thread resume, steering, interruption, history and approvals. Installed-version schemas and live outcomes determine the queue behavior here.

See the [results and architecture implications](../../.plans/2026-11-10-worker-delivery-results.md).
