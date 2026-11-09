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
