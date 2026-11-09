# Claude Opus 5.5 with the existing computer-use plan

November 9, 2026. **Yes: a live Opus 5.5 run successfully used our existing Pi → Codex native MCP path.** Only the model provider in the isolated CLI changed; the shared harness, runtime tools, permission policy and image adapter stayed the same. This establishes model/backend compatibility. It does not yet establish browser-task quality or a right to ship the proprietary runtime with another model.

Reproduction: [Pi probe](../experiments/pi-cua-probe/README.md). Sanitized measurements and source fingerprints: [evidence](evidence/2026-11-09-browser-runtimes/claude-and-runtime-contract.json). The [runtime integration contract](2026-11-09-runtime-integration-contract.md) covers the remaining parts of review item #1.

## What the current official material actually says

Anthropic released **Claude Opus 5.5** on September 22, 2026; its API ID is `claude-opus-5-5`. Published pricing is **$4/M input, $20/M output, $0.20/M cache reads**, and $5/M ordinary cache writes. Anthropic reports over 30% faster output generation and roughly 40% lower typical task cost **relative to Opus 5**. Those comparisons do not establish an advantage over our GPT-6.1 Sol configuration. Its reported OSWorld 2.1 result is **81.8% partial**, generally at max adaptive-thinking effort; OSWorld is not our browser workflow or this low-effort probe. [Announcement and benchmark conditions](https://www.anthropic.com/claude-opus-5-5).

Current model documentation confirms image input and tool use. Pi 1.4.0 already includes this exact model in its Anthropic catalog with matching prices; no SDK/package upgrade was necessary. We explicitly selected low effort for these simple tasks. Effort labels across vendors are not equivalent compute budgets. [Model capabilities](https://platform.claude.com/docs/en/models/overview).

## Four combinations that should not be conflated

| Reasoning and tool interface | Execution backend | Status / implication |
| --- | --- | --- |
| Opus through Pi's ordinary custom tools | Installed Codex native MCP | **Live pass.** The same `js` tool, returned guidance, AX observations and images work with Opus. This preserves the existing native/capture/presentation architecture. |
| Opus through those same tools | Installed Codex specialized Chrome backend | **Live rejection.** The missing current-turn authorization remains. Changing the model does not provision a desktop browser session. |
| Opus through ordinary MCP tools | An independently usable browser provider, such as the previously tested Playwright MCP | Fits the current adapter in principle; **not live-tested with Opus in this addition**. This would change the execution provider, not the model loop. Keep it as an explicit fallback choice, not a silent replacement for the user's Codex preference. |
| Opus through Anthropic's browser/computer toolsets | A driver implementing the Anthropic contract | Publicly documented alternative. Requires an additional toolset adapter/driver; not the interface exercised by our successful native run. |

The model is the reasoning component; the tool schema describes operations; the driver executes them; the renderer/capture path supplies the Vision surface. These are separate choices. Choosing Claude does not require replacing Pi, adopting Claude Code, changing the stream codec or moving workspace ownership off the Mac.

## Anthropic's browser interface is worth evaluating separately

The documented `browser_toolset_20260801` provides page-aware operations and screenshot/coordinate input. Our application supplies the browser executor; Anthropic does not run those calls remotely. Tool calls/results carry `toolset_name`, and browser state has a dedicated `browser_state` representation. Default tool definitions add roughly 6,600 input tokens before screenshots/page state; disabling members reduces that overhead. [Browser tool contract](https://platform.claude.com/docs/en/agents-and-tools/tool-use/browser-use-tool).

The corresponding `computer_toolset_20260801` is a screenshot/coordinate desktop interface. It is distinct from Codex's app-scoped AX-plus-JavaScript interface. Current computer toolset coordinates use the returned screenshot's pixel space; older examples with explicit display dimensions are not the current schema. [Computer tool contract](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool).

Anthropic supplies SDK driver base classes and lists partner integrations. Its sample browser driver uses Chromium/CDP and is explicitly not production code. The SDK can provide the tool loop and configured checks, but the host still owns the browser and closes the driver. If we evaluate this route, connect it to the same target ownership and presentation boundary rather than creating a separate window registry. [SDK toolsets and driver responsibilities](https://platform.claude.com/docs/en/agents-and-tools/tool-use/browser-use-sdk).

Our pinned Pi adapter currently converts ordinary tool calls into its common text/image tool-result representation. Inspection found no `toolset_name` or `browser_state` handling in that converter/common tool-call type. Therefore **switching `--provider anthropic` does not activate Anthropic's native toolsets**. A toolset-specific transport/result adapter would need testing. The current custom-MCP route already works and does not need that extra implementation to use Opus.

## Live results

The local Poncho2 Anthropic credential was rejected as invalid. A different existing credential in the user's authorized `merit-systems` tree worked. Only the named key was loaded into the model client; no key value was logged or inherited by the CUA subprocess.

| Case | Observed result |
| --- | --- |
| Synthetic image MCP fixture | **Pass**, 4.319 s, first tool dispatch at 1.408 s; image interpreted correctly and one answer accepted. SDK-estimated token cost: **$0.00998**. |
| Actual native app | **Pass**, 12.724 s, first tool dispatch at 2.444 s, three MCP calls, one model-visible screenshot, no tool errors. State file and screenshot independently confirm `Counter: 2` and `pi-direct`. SDK-estimated token cost: **$0.07639**. |
| GPT baseline retry on the same native task | **Pass**, 10.302 s, first tool dispatch at 2.849 s; three MCP calls and one image. SDK-estimated token cost **$0.00889**, following a failed attempt costing **$0.01417**. Cache conditions differ from the Opus run. |
| Actual Chrome initialization | **Rejected**, 5.009 s; one tool call returns `Cannot verify browser access without the current turn`. Opus reports it and stops without retries or fallback. |

These are compatibility smoke tests, one successful Opus run per task, not a controlled speed/quality benchmark. The earlier GPT native run completed in 11.49 s. A new GPT attempt during this comparison hit ScreenCaptureKit `-3811` before changing the fixture; that infrastructure failure is retained in the evidence and analyzed in the runtime note. It must not be scored as a model reasoning failure or silently removed from overall task reliability. After we verified no mutation, a fresh connection completed the GPT task; state and screenshot agree. These successful samples do not show Opus faster or cheaper than GPT here, and the different cache conditions preclude a clean cost ratio.

Costs are the pinned Pi SDK's list-price estimates from reported token usage, including cache categories; they are not invoice measurements. Prompt caching, output verbosity, image size, model effort and native runtime startup can all change the total. The elapsed measurement includes the tool loop. We have not measured continuous browser work, sustained throughput, retries per completed task or takeover latency.

## Decision and next useful evaluation

Keep Opus 5.5 as a concrete candidate for the ephemeral coordinator. The model/backend boundary is already small enough to compare it without adding a production provider framework. Do not choose a model solely on a vendor's headline computer-use score or token price.

Once a browser execution path is qualified, compare both models on the same approved cases: reach Settings; fill a disposable form and verify it; operate two separate targets; recover from a stale page; and Stop for human takeover. Hold the browser provider and fixture fixed first. Record success, first visible action, completion time, actual input/output/cache tokens, cost per successful task, wrong-target actions and interventions. Then separately compare custom MCP tools with Anthropic's native toolset if there is a measurable reason to do so. Avoid changing both model and driver and attributing the result to the model.

No production, headset, lock or parallel-input tests were run here. Seven existing harness regression tests pass. The user-approved direction remains a small Mac coordinator, existing resource owners, and the existing Vision gateway.
