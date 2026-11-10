# Runtime qualification: real terminal client and native cold start

November 9, 2026. Execution of review item #1, after the [owned browser prototype](2026-11-09-owned-browser-extension-probe.md). [Evidence and artifact hashes](evidence/2026-11-09-browser-runtimes/runtime-qualification.json).

**The remaining local integration paths now work on the measured installation:** a real terminal Codex CLI can use our browser MCP alongside Pi, and an independent native MCP client can start and recover the installed Mac helper with ChatGPT closed. This is enough to proceed with the first application integration. It is not a supported SDK/shipping license, a fresh-machine permission test, or an update-compatibility guarantee.

## Real Codex CLI alongside Pi

Ran actual `codex exec` **0.167.0**, not a simulated MCP client or desktop-created child task. Its normal local login supplied inference authentication. Pi used the existing API-backed harness. Each held its own MCP connection and fixture tab in one isolated visible Chrome for Testing profile.

The CLI invocation used an empty temporary working directory, `--ephemeral`, `--ignore-user-config`, read-only filesystem sandbox, disabled shell/apps/plugins/web search, and per-invocation `mcp_servers.owned_browser` configuration. The transcript contained only agent messages and calls to that server. No desktop browser identity or private browser access host was supplied. The model was left at the CLI default; the Pi peer used `gpt-6.1-sol`.

Both consumers saved their distinct label, incremented exactly twice, opened Settings, verified fresh AX state and received an actual screenshot. Independent fixture events confirmed the effects. CLI completion took 49.3 seconds and 13 tool calls in this one run. The lifetimes overlapped, but the Pi action events preceded Codex's action events; this run is not evidence of simultaneous input dispatch. Earlier model-free tests exercised interleaved clients.

Normal CLI exit released its own tab lease while Pi retained its lease. A second real CLI task began a bounded 30-click cancellation fixture. After the first independently recorded increment, the test sent SIGINT to that owned CLI process. It exited with code 1, its lease was released, and no further increments appeared during the subsequent one-second observation period. Pi then used its existing tab and reached Counter: 3. This establishes the `codex exec` lifecycle, not Escape/key routing in the eventual interactive xterm UI.

### Two setup details matter

- The first run discovered our server but rejected `browser_open`: `MCP tool call requires approval, but approval policy is never`. `never` is not a grant to MCP write tools. The successful run explicitly set `mcp_servers.owned_browser.default_tools_approval_mode="approve"` for this user-authorized, fixture-origin-restricted server only. No global trust settings changed. A production adapter still needs the intended target/origin grants; do not translate this disposable-fixture setting into blanket approval of unrelated servers. [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- This machine resolved **0.153.4** from `~/.local/bin/codex` in the experiment shell and **0.167.0** from `~/.bun/bin/codex` in the root shell. The runner now accepts an explicit `--codex` path and records its version. We did not update either installation. Qualify the executable the session service will actually launch, rather than assume PATH is uniform.

Reproduce with [terminal-qualification.mjs](../experiments/owned-browser-probe/terminal-qualification.mjs). It launches its own temporary browser host, tests the actual CLI and Pi, checks fixture events, interrupts only its own CLI child and cleans up.

## Native close, relaunch and Stop

The native tests use the genuine installed launcher, discovered MCP schemas and scoped approval for only `dev.slopzooka.codex-runtime-fixture`. They invoke the same native provider directly through MCP without model inference, isolating lifecycle behavior from model choices.

**An app handle is not an immutable process/window handle.** In all three corrected warm cycles and all three cold cycles, requesting state through the old handle after closing the fixture reopened the application with a new PID and Counter: 0. Reading the old handle after a separate explicit relaunch also followed the new instance. These were read-only observations; no prior click was replayed.

This means a production consumer must not treat a successful `getApp` handle as proof of exact scene identity. The shared surface binding needs explicit lifecycle/generation semantics for observations as well as mutations: an apparent read can launch the app. A PID precheck alone cannot make several opaque provider calls atomic across an app replacement. Whether the provider can enforce the exact desired window binding belongs in item #3's control/presentation integration; fail or require a fresh binding when identity is uncertain.

Native Stop was exercised with one script that could perform five clicks separated by 400 ms. Once the state file confirmed the first click, we closed its owned MCP client. Close acknowledged in about **0.5 seconds**; its MCP process exited; the counter remained 1 through a **2.5-second** observation period. A fresh connection then observed the correct state. This is bounded empirical cancellation evidence, not a promise to undo dispatched input or cancel every possible native operation.

### The user-visible fixture crashes were our bug

The first relaunch experiment caused two macOS “quit unexpectedly” alerts. The crash reports showed `SIGTRAP` in `FixtureDelegate.init()`: our fixture force-unwrapped a launch-only environment variable. The native provider's automatic relaunch omitted that environment, exposing the fixture bug. This was not a demonstrated crash of the vendor helper.

We stopped the test, closed the leftover owned fixture, and changed the fixture to accept a per-run state path in its bundle plist, with a safe fallback when no environment is present. The runner now builds its own disposable app and cleans up instances that the provider automatically reopens, including failure paths. The corrected warm and cold runs created no additional fixture crash reports. The two original failures remain recorded; the earlier ScreenCaptureKit `-3811` failure remains unexplained and was not reproduced in these short runs.

## Cold startup and helper recovery: completed in the approved slot

The user explicitly approved briefly closing ChatGPT and stopping its shared helper. The [cold-slot wrapper](../experiments/pi-cua-probe/cold-slot.mjs) quit ChatGPT normally, verified both processes were absent, started the independent qualifier, and reopened ChatGPT in `finally`.

Observed:

1. Before client startup, neither ChatGPT nor `SkyComputerUseService` was running.
2. The genuine native MCP launcher started the helper. Initial app attachment took about **1.0 second** and subsequent screenshot and click operations succeeded.
3. Three fixture close/relaunch cycles and the bounded Stop test completed while ChatGPT remained closed.
4. We deliberately sent SIGTERM to the verified shared helper process, with the desktop still absent. The existing MCP connection's next observation recovered and produced a screenshot in **0.82 seconds**. A fresh MCP connection also succeeded and returned a fresh screenshot. The helper PID changed.
5. No fixture input was replayed during recovery. ChatGPT stayed closed throughout the measured native sequence, then the wrapper reopened it successfully. The user's normal desktop/helper processes were present afterward.

The tested failure was process termination between calls, **not** SIGKILL during a native mutation or corruption of the helper installation. The already installed vendor app and existing macOS permissions remained in place. We did not test a clean account, permission revocation, a signed production SlopZooka build, lock/sleep, or every in-flight helper failure. The desktop GUI is therefore not a necessary _running process_ for this measured native path; the installed runtime remains a dependency.

## Exact qualified tuple and update behavior

| Component                                     | Measured value                                                                              |
| --------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Terminal CLI                                  | 0.167.0, explicit executable; 0.153.4 encountered in the initial setup failure              |
| Desktop installation / native plugin manifest | 26.1103.60933                                                                               |
| Native helper bundle                          | 26.1102.1001824; OpenAI Team ID `2DC432GLL2`                                                |
| Native MCP server                             | `rmcp` 3.5.1; protocol 2025-11-25                                                           |
| Native catalog                                | `js`, `js_add_node_module_dir`, `js_reset`, `turn_ended`; Pi grants only the required tools |
| Browser test host                             | Chrome for Testing 157.0.8103.15; our extension and MCP implementation                      |

The evidence fingerprints the manifest, native tool catalog, launcher executable, helper executable and native-pipe adapter. Different desktop/helper version strings are normal in this observed tuple; comparing the strings for equality would incorrectly reject it. The inspected native adapter performs its own client/server API-version ping and rejects mismatches. That is source evidence; we did not alter installed components to force a mismatch.

The minimum integration policy should be: discover the installed manifest, preserve the genuine launcher and trusted-service configuration, exclude inherited desktop task/turn identity, read current tool schemas/guidance, and record the actual tuple. Re-run initialization, disposable input/image and cleanup checks after a tuple/schema change before labeling it qualified. Report unavailable/incompatible state explicitly and never replay uncertain mutations. This is a qualification policy, not a new durable coordinator or a completed auto-update support matrix.

## What remains within item #1

- **Production installation/permission attribution:** qualify the actual signed companion and installer on a clean permission state, with repair/deep-link UX. Our working runtime retained the vendor helper's existing grants.
- **Upgrade qualification:** adopt the small version/schema check above, then exercise it against a real update. No guarantee for an untested release follows from this one tuple.
- **Vendor dependency terms/support:** obtain a concrete answer for invoking the user's existing native installation from SlopZooka, using non-OpenAI models with it, any packaging rights, and compatibility/support expectations. The public CLI's open-source status does not answer those questions for the opaque helper. Current Service Terms section 10 restrict modification/redistribution/sublicensing and link licensed-material use to permitted Services use; applicability to the exact integration requires confirmation under the relevant agreement. We found no public standalone native-runtime embedding/support contract. [Service Terms](https://openai.com/policies/service-terms/)

The owned browser path does not inherit that private native-runtime dependency. Stable Chrome extension installation and general-site permission policy remain product qualification, rather than a missing Codex caller interface. No message to OpenAI or another party was sent as part of this research.

## Validation scope

Passed: real CLI/Pi fixture completion, actual CLI interruption and peer continuation; corrected warm native lifecycle tests; approved cold startup/helper recovery; seven Pi harness tests and two browser framing tests. Fixture compilation was exercised through `swiftc`; the new JavaScript files were formatted and syntax checked. Production application sources and dependencies are unchanged. The preceding full repository checks and visionOS simulator build remain recorded in the [owned-extension report](2026-11-09-owned-browser-extension-probe.md#verification-and-references); they were not a physical-device test of this integration.
