# Agent orchestration and shared surfaces: reading guide

Research and live discovery from October 31–November 1, 2026, with a streaming-strategy reference review on November 6, offline Mac codec benchmarks and Codex harness inspection on November 8, and browser-host/OSS provider investigation on November 9. These documents distinguish proposed architecture, source inspection, local measurements and observed device behavior. They do not implement the production orchestrator or approve the entire sample-prompt catalog.

## Start here

1. [Execution and presentation architecture](orchestrator-execution-path.md): the current design focus. Follow one request from voice/Pi, through local Mac tool execution, into a new streamed Vision window, and back through observed results. Includes the terminal Codex MCP path and the missing production connections.
2. [Live findings](shared-window-live-results.md): what the physical Mac/Vision Pro experiment established, failures and fixes, lock/unlock evidence, cleanup and remaining limits.
3. [Coordinator and tool responsibilities](orchestrator-tools.md): ephemeral Pi, voice delegation, shared providers, context, workspace naming and actual Poncho2 findings.
4. [Implementation and rollout sequence](orchestrator-execution-path.md#implementation-testing-and-rollout-sequence): extend the existing gateway, integrate one controllable preview, connect the real agents, then expand workspace launch, voice and opt-in use. Each stage has an observed completion criterion.
5. [Streaming strategy clarification](macos-window-streaming.md#8-streaming-strategy-review-november-6-2026): tested H.264/native rendering, the HEVC comparison, simulator JPEG transcoding, direct LAN versus peer-to-peer Wi-Fi, and why Foveated Streaming is a different workload.
6. [Mac codec benchmarks](2026-11-08-mac-codec-benchmarks.md): 26 hardware encode/decode cases, raw evidence and test journal; retain H.264 initially, compare ordinary real-time HEVC on the headset, and test JPEG→H.264 fallback transcoding.
7. [Codex Mac CUA harness inspection](2026-11-08-codex-computer-use-harness.md): official docs, pinned CLI source and installed runtime inspection; concrete observations/actions, native IPC, cleanup hooks, identity limits, background/locked behavior and the small pieces worth adopting.
8. [Open-source Mac CUA options](2026-11-08-macos-cua-options.md): comparison/fallback providers, source-level background-input findings, OpenAI custom-tool integration and a local Codex import probe. The later Codex preference below supersedes the initial open-source-first evaluation order.
9. [Working Codex runtime reuse experiment](2026-11-08-codex-runtime-reuse.md): the bundled MCP launcher successfully drove a disposable Mac app from our own independent launcher, without a new Codex agent or supplied turn metadata. Includes the concrete unstable interface, verified effects and a shortcut that did not produce its intended effect.
10. [Codex preference, Chrome backend and guidance](2026-11-08-codex-browser-and-guidance.md): prefer the installed Codex runtime, with an interface/tradeoff review before committing to ship it. Browser-specific APIs, local guidance collection, and the standalone browser probe's separate session-authorization failure.
11. [Deeper browser-runtime investigation](2026-11-09-browser-runtime-options.md): the actual desktop access-host provisioning, additional Codex boundary checks, six OSS options and local Playwright MCP / Playwriter / agent-browser trials. Includes caller-owned context injection, strict tab-closure failure and shared-browser authority limits.
12. [Background Chrome extension control](2026-11-09-background-browser-control.md): official extension package inspection, tab-targeted CDP, focus emulation, logical versus visibly selected tabs, turn cleanup, and the distinct requirements for streaming the same page without taking desktop focus. Includes a narrow live qualification matrix; no extension was installed or live-tested.

Guidance is already collected locally: the [guidance audit](2026-11-08-codex-browser-and-guidance.md#november-9-audit-desktop-runtime-versus-cli-itself) distinguishes 52 verified installed-runtime documents from nine release-matched public CLI source/reference files. It identifies what a future Pi adapter should load dynamically and what remains implementation work.

## Supporting research

| Document | Contents |
| --- | --- |
| [Broad exploration](agent-managed-surfaces.md) | Product direction, alternative harness/streaming approaches, Codex tool research, wrist integration, window placement, workspace prompts and references |
| [Mac streaming research](macos-window-streaming.md) | Capture/control permissions, transports, encoding, lock behavior and fallback options |
| [Isolated experiment plan](shared-window-prototype.md) | Preparation, acceptance cases, measurement and cleanup plan; historical setup notes are superseded by the live report |
| [Shared-control UX cases](shared-control-ux-spike.md) | Subsequent tests for global-agent/terminal-agent target retention, interruption and handoff; direct headset editing requires an additional input path |
| [Probe source and instructions](../experiments/shared-window-probe/README.md) | Disposable native host, Vision receiver, fixtures, capture/device adapters, checks and session scripts supporting the findings |

## Current direction

Use a small Pi coordinator in the existing Mac companion, with the chosen voice frontend delegating tasks. Terminal coding agents access the same application handlers through MCP. Existing services retain workspace/process ownership, providers own capture/control, and Vision's existing `WindowGateway` retains presentation ownership. The model discovers how to launch and navigate an app; application code supplies stable targets and observable effects.

The user's current preference is **Codex's installed CUA runtime** rather than starting with an open-source driver. Independent native reuse is demonstrated. The specialized browser provider has a distinct unresolved Codex session/access dependency, but **Chrome also works through native Mac CUA**: a November 9 live test operated page fields, buttons and an iframe without invoking the browser provider. Do not make specialized browser provisioning a prerequisite for the first web demo. Revisit interfaces, operational independence and release terms with the user before making a shipping commitment. Keep the open-source comparison available without implementing multiple providers up front.

The November 9 browser experiments provide working model-free alternatives: Playwright MCP accepted companion-owned browser contexts, Playwriter retained JavaScript page handles over direct CDP, and agent-browser rejected closed pinned targets. These headless local trials do not establish extension takeover, native capture identity or Vision streaming. Browser provider choice can be evaluated separately from native Mac control while retaining the same ownership and presentation boundaries.

The immediate integration is one model-driven simulator request through the real execution and presentation path. The exact tool catalog, voice API choice and larger workflow prompt set remain design work. Broad feasibility retesting and polished handoff UI are not prerequisites for specifying that path.

## Evidence boundaries

Native multi-window streaming and independent simulator streaming/input were exercised on a physical Vision Pro. The user confirmed the final locked simulator counter changes and native-view recovery after unlock. These results do not establish full-system sleep support, cold simulator boot while locked, production Pi/MCP integration, automatic exact-window association or direct headset pointer/keyboard interaction. Standalone XCTest failures remain recorded.

The probe is isolated from production sources and build dependencies. Local builds, device recordings/screenshots, live-session logs, connection files, certificates and keys remain ignored. The repository contains written findings, reproduction sources, and the synthetic benchmark's credential-free measurement JSON, CSV and journal. Source references in the notes are pinned to the inspected revisions, including older baselines; use the current application architecture when implementing the proposal.
