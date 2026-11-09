# Installed Codex runtime experiment

This is the small, machine-specific scaffold used on November 8, 2026 to test the **installed** Codex Mac computer-use runtime from a separate application. It is not a production dependency or a general automation client. See [findings and exact limits](../../.plans/2026-11-08-codex-runtime-reuse.md) and [recorded evidence](../../.plans/evidence/2026-11-08-codex-runtime-reuse/results.json).

- `client.py` reads the installed unified-computer-use manifest, preserves its launcher configuration, narrows it to the native computer provider and speaks MCP stdio. Its default mode reads inventory and exits. `--fixture` enables an interactive JSON-lines command loop and accepts app elicitations **only** for `dev.slopzooka.codex-runtime-fixture`; all other app requests are canceled.
- `Fixture.swift` creates a disposable native text field and counter. It writes actual state to `SLZ_CUA_FIXTURE_STATE`; this is an independent effect check rather than trusting the tool response.
- `Launcher.swift` starts that client from its own Mac app, records its parent PID and inherited environment names, and pipes a local command file into the client. It has intentionally fixed temporary paths and the Python path used during discovery.

These files are the tested source snapshots, with hashes in the evidence record. The native runtime itself is not copied here. The client must be given only code intended for this fixture; it is not a security sandbox for arbitrary scripts. It reports tool results, not automated pass/fail judgments. Screenshots, installed-app inventory and bootstrap documentation should remain local; committed traces contain only fixture state and redacted inventory summaries.

## Read-only launcher check

With the exact inspected app/plugin still installed:

```sh
python3 experiments/codex-runtime-probe/client.py
```

This starts our own instance of the bundled MCP launcher, obtains its catalog and inventory, then closes that instance. It leaves the shared native helper alone. Do not substitute another build silently if the pinned manifest path is missing; inspect and record the new version first.

## Fixture and independent-app setup used in discovery

The test used these temporary locations:

```text
/tmp/slz-codex-runtime-probe.py                copy of client.py
/tmp/slz-codex-runtime-fixture.swift           copy of Fixture.swift
/tmp/slz-codex-runtime-launcher.swift          copy of Launcher.swift
/tmp/slz-codex-runtime-fixture/
  Slz Runtime Fixture.app/Contents/MacOS/SlzRuntimeFixture
  Slz Runtime Client.app/Contents/MacOS/SlzRuntimeClient
  commands.jsonl
  state.json
  launcher.json
  launchservices-results.jsonl
```

The Swift files were built with `xcrun swiftc`; the fixture links AppKit. Each app has an ordinary `Info.plist` with the matching executable, `CFBundlePackageType=APPL`, version `1`, and its own bundle identifier:

- Fixture: `dev.slopzooka.codex-runtime-fixture`.
- Client: `dev.slopzooka.codex-runtime-client`, with `LSUIElement=true`.

Only these new apps were ad-hoc signed. The installed OpenAI executables kept their original signatures. The fixture was opened with `open -g -n`, passing `SLZ_CUA_FIXTURE_STATE=/tmp/slz-codex-runtime-fixture/state.json` through `open --env`. The client app was separately opened with `open -g -n` from an environment containing only ordinary path/home/locale/user variables. Its recorded parent PID was `1`, with no inherited Codex variables.

For an interactive fixture test, run the client with `--fixture`; each input line is `{"code":"..."}`, or `{"exit":true}`. Attach with `cua.getApp` using the fixture's exact path and inspect the returned state before selecting a control. The independent launcher uses the same lines in `commands.jsonl`. `semantic-commands.jsonl` retains the final scripts and the semantic trace retains their results; fresh element indices must always come from the current observation rather than a saved numeric ID.

On completion, close only the owned MCP process group and the fixture PID after verifying its executable path. Normalize `/tmp` and `/private/tmp` when comparing identity. Do not terminate the shared `SkyComputerUseService`, alter its permissions or close the user's Codex application. The test clients do not mutate installed configuration or request persisted app approvals.

The successful smoke tests do not qualify every key chord, background action, permission state or runtime version. In particular, the select-all trial did not establish the requested selection, despite a non-error response. The observed fixture results, including that limitation, are authoritative.

## Local guidance collection

Run `python3 experiments/codex-runtime-probe/collect-guidance.py` to copy documentation from the inspected app version into ignored `build/guidance/26.1023.51421/`. The script verifies the app version and ignored destination, then records source paths, lengths and SHA-256 hashes. It does not launch/control applications or modify Codex configuration. Vendor documentation remains local; the repository contains our summaries and fingerprints. Use live MCP descriptions and first-use documentation when driving the runtime rather than treating this cache as a permanent prompt.

The [browser and guidance follow-up](../../.plans/2026-11-08-codex-browser-and-guidance.md) records the 52-file collection and a read-only browser variant of the native probe. That variant preserved the installed preloader and trusted-service configuration, enabled only `browser`, and called `cua.listBrowsers()`. MCP startup worked; browser discovery rejected missing current-turn authorization. Its output is [recorded separately](../../.plans/evidence/2026-11-08-codex-browser-guidance/browser-discovery.jsonl). This is not evidence of successful browser reuse.

The November 9 audit separately cached nine public CLI reference files at the release matching installed CLI `0.167.0`, under `build/cli-guidance/086ccc833bc9cf01024ad2dd6af7dbd421b6bf9a/`. The [manifest](../../.plans/evidence/2026-11-09-browser-runtimes/cli-guidance.json) provides immutable source URLs, blob SHAs and cache hashes. These cover skill-use instructions/loading, native policy types and turn cleanup; they are separate from the desktop provider's operational guidance. No dedicated browser/Mac CUA `SKILL.md` was found in that public release tree. Neither collection installs a skill into Pi or global Codex configuration.

## Owned App Server browser task

`app-server-task.mjs` is the November 9 follow-up for an **explicitly authorized new Codex test task**. Unlike the inventory checks, it starts a model turn and consumes normal Codex usage. It is pinned to desktop `26.1103.60933` and the already-running App Server `0.167.0`; it never starts or restarts the shared daemon. Its WebSocket dependency is the `ws` package already staged by the [browser comparison](../browser-runtime-probe/README.md).

Start `serve-fixture.mjs` from that comparison, then supply its exact loopback `/b` URL:

```sh
node experiments/codex-runtime-probe/app-server-task.mjs http://127.0.0.1:<fixture-port>/b
```

The client initializes through the normal App Server Unix-socket WebSocket connection, creates one ephemeral thread in a new empty temporary directory, and registers the genuine installed MCP launcher as `slz_browser_probe`. It supplies only the browser surface, retaining the packaged runtime environment and checks. It does not copy another task's identity or desktop access-host connection. Codex supplies its own task/turn metadata. The model uses the configured default, operates only the dummy fixture if browser initialization succeeds, and reports the exact error otherwise. No native/IAB fallback is allowed by the test instructions.

The working directory is read-only for the agent, and the client never changes personal configuration. **Per-thread MCP configuration merges existing server configuration**: other configured servers can start even though the test agent is instructed to call only the probe server. This is a narrowly instructed experiment, not a hardened tool sandbox. The recorded run made exactly one tool call, to the intended probe. Unexpected host/permission requests are canceled and recorded distinctly; none occurred in this run.

Results, the tool catalog and local trace are written under ignored `build/app-server-task-*`. On completion, the client unsubscribes its own thread, closes its connection and removes only its empty temporary directory. It leaves the shared daemon and user tabs running. Do not blindly rerun after a mutation timeout; first inspect whether the task was created.

**Observed result:** the genuine model turn called the browser tool, which returned “The browser access host is unavailable.” No `/b` events occurred. The turn completed by reporting that failure. This passes task creation/current-turn propagation but does not pass browser provisioning. See the [runbook result](../../.plans/2026-11-09-background-browser-control.md#owned-codex-task-result) and [sanitized evidence](../../.plans/evidence/2026-11-09-browser-runtimes/owned-task.json).

The [subsequent bootstrap inspection](../../.plans/2026-11-09-background-browser-control.md#8-desktop-bootstrap-traced-after-the-owned-task-failure) locates the missing per-task configuration in the desktop app service. It also distinguishes generic App Server tool calls from desktop task delegation and records an existing SSH-forwarded desktop MCP bridge. These are source findings, not a successful independent browser adapter. Repeating this static-manifest probe without a new provisioning path is not the next test.
