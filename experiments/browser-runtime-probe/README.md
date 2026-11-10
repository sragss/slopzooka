# Disposable browser-provider comparison

November 9, 2026. [Findings](../../.plans/2026-11-09-browser-runtime-options.md) and [evidence](../../.plans/evidence/2026-11-09-browser-runtimes/results.json). This is a Mac-specific research scaffold, not a production browser service or an autonomous agent.

`probe.mjs` starts a loopback fixture and a headless Chrome with a new empty profile. It connects two Playwright MCP servers to companion-owned browser contexts, one Playwriter MCP client over direct CDP, and two named agent-browser CLI sessions on request. No personal browser profile, extension, login, model API or Vision stream is involved. The installed Codex bundle supplies only the Node 24 executable for these OSS tests.

## Prepare and run

For the **Codex desktop/browser-runtime baseline**, use the existing fixture without starting any OSS provider or a second Chrome:

```sh
node experiments/browser-runtime-probe/serve-fixture.mjs
```

This dependency-free server binds an ephemeral port on `127.0.0.1` and prints exact `/a`, `/b` and `/events` URLs. It serves the same disposable controls used in the earlier comparison and writes fixture events to an ignored `build/codex-baseline-*/events.jsonl`. It does not install an extension, change browser permissions, open tabs or provision Codex authorization. Keep it running during the browser task; Control-C stops only this server. Use dummy labels only.

First test one page from a legitimately provisioned desktop chat using the browser-specific tool route: open its exact `/a` URL, save `codex-a` as the workspace label, increment twice, open Settings, and verify the rendered result. Inspect `/events` independently; there should be one save, two increments and one settings event for `/a`. A native `getApp("com.google.Chrome")` success does not pass this browser-provider test. Use `/b` with a distinct label for the later second-owner test. These are proposed fixture operations for runtime qualification, not approval of the broader product prompt catalog. See the [gated runbook](../../.plans/2026-11-09-background-browser-control.md#7-runtime-qualification-runbook).

The following original commands run the separate **OSS comparison**, not the Codex authorization experiment.

From the repository root:

```sh
npm install --prefix experiments/browser-runtime-probe/build/runtime --ignore-scripts --no-audit --no-fund @playwright/mcp@0.0.84 agent-browser@0.41.2 playwriter@0.10.0 @modelcontextprotocol/sdk@1.30.0
chmod u+x experiments/browser-runtime-probe/build/runtime/node_modules/agent-browser/bin/agent-browser-darwin-arm64
/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node experiments/browser-runtime-probe/probe.mjs
```

Use an interactive terminal, or pipe a prepared command file. The process prints `ready` with its unique run directory, fixture origin and owned CDP endpoint. It reads JSON objects, one per line. All artifacts, packages, profiles and copied research sources stay in ignored `build/`. Actual resolved package versions/integrities are recorded in the evidence; the reviewed GitHub heads are separate evidence and differ from some published npm artifacts.

Examples below describe the input shape. Substitute the just-returned origin/endpoint and current snapshot references:

```json
{"actor":"playwright-a","tool":"browser_navigate","arguments":{"url":"http://127.0.0.1:<fixture-port>/pw-a"}}
{"actor":"playwright-b","tool":"browser_tabs","arguments":{"action":"list"}}
{"actor":"playwriter","tool":"execute","arguments":{"code":"console.log(context.pages().map(p => p.url()));"}}
{"actor":"agent-a","args":["--cdp","http://127.0.0.1:<cdp-port>","--pin-tab","open","http://127.0.0.1:<fixture-port>/agent-a"]}
{"observe":true}
{"closeUrl":"http://127.0.0.1:<fixture-port>/agent-a"}
{"actor":"agent-a","args":["get","url"]}
{"disconnect":"playwright-a"}
{"exit":true}
```

Read `*-catalog.json` before issuing tools; do not assume old argument names. The tested Playwright MCP uses `target`, and some responses link snapshots/screenshots on disk. Use absolute screenshot filenames inside the returned run directory: relative filenames can resolve against the caller's working directory. Our initial `pw-a.png` was moved from the repository root into the ignored run directory after capture.

The fixture reports actual save, increment and settings actions to its loopback server. `observe` returns those independent events plus current owned-page metadata. `closeUrl` closes exactly one matching fixture URL to test stale handles. The JSONL trace records both expected errors and successful effects; a tool's non-error return is not an assertion of success. The committed trace is a historical transcript, not a script to replay stale element IDs or ports.

On exit, the scaffold closes only its two named agent-browser sessions, its MCP clients/contexts, and its own Chrome child. It leaves the shared Codex helper and personal browser untouched. The first interactive version needed terminal EOF after resource cleanup; the final version releases stdin and passed a separate startup/exit smoke check. An earlier attempt incorrectly executed Playwriter's exported implementation module instead of its CLI entry point; the final version starts `bin.js`.

This harness accepts code and CLI commands for **owned fixtures only**; it is not a sandbox for untrusted agents. In particular, Playwriter's direct-CDP connection could enumerate other fixture contexts. No claim of extension authorization, adversarial isolation, physical window identity, human takeover or streaming reliability follows from these tests.
