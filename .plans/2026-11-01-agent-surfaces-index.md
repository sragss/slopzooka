# Agent orchestration and shared surfaces: reading guide

Research and live discovery from October 31–November 1, 2026, with a streaming-strategy reference review on November 6, plus offline Mac codec benchmarks and Codex harness inspection on November 8. These documents distinguish proposed architecture, source inspection, local measurements and observed device behavior. They do not implement the production orchestrator or approve the entire sample-prompt catalog.

## Start here

1. [Execution and presentation architecture](orchestrator-execution-path.md): the current design focus. Follow one request from voice/Pi, through local Mac tool execution, into a new streamed Vision window, and back through observed results. Includes the terminal Codex MCP path and the missing production connections.
2. [Live findings](shared-window-live-results.md): what the physical Mac/Vision Pro experiment established, failures and fixes, lock/unlock evidence, cleanup and remaining limits.
3. [Coordinator and tool responsibilities](orchestrator-tools.md): ephemeral Pi, voice delegation, shared providers, context, workspace naming and actual Poncho2 findings.
4. [Implementation and rollout sequence](orchestrator-execution-path.md#implementation-testing-and-rollout-sequence): extend the existing gateway, integrate one controllable preview, connect the real agents, then expand workspace launch, voice and opt-in use. Each stage has an observed completion criterion.
5. [Streaming strategy clarification](macos-window-streaming.md#8-streaming-strategy-review-november-6-2026): tested H.264/native rendering, the HEVC comparison, simulator JPEG transcoding, direct LAN versus peer-to-peer Wi-Fi, and why Foveated Streaming is a different workload.
6. [Mac codec benchmarks](2026-11-08-mac-codec-benchmarks.md): 26 hardware encode/decode cases, raw evidence and test journal; retain H.264 initially, compare ordinary real-time HEVC on the headset, and test JPEG→H.264 fallback transcoding.
7. [Codex Mac CUA harness inspection](2026-11-08-codex-computer-use-harness.md): official docs, pinned CLI source and installed runtime inspection; concrete observations/actions, native IPC, cleanup hooks, identity limits, background/locked behavior and the small pieces worth adopting.

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

The immediate integration is one model-driven simulator request through the real execution and presentation path. The exact tool catalog, voice API choice and larger workflow prompt set remain design work. Broad feasibility retesting and polished handoff UI are not prerequisites for specifying that path.

## Evidence boundaries

Native multi-window streaming and independent simulator streaming/input were exercised on a physical Vision Pro. The user confirmed the final locked simulator counter changes and native-view recovery after unlock. These results do not establish full-system sleep support, cold simulator boot while locked, production Pi/MCP integration, automatic exact-window association or direct headset pointer/keyboard interaction. Standalone XCTest failures remain recorded.

The probe is isolated from production sources and build dependencies. Local builds, device recordings/screenshots, live-session logs, connection files, certificates and keys remain ignored. The repository contains written findings, reproduction sources, and the synthetic benchmark's credential-free measurement JSON, CSV and journal. Source references in the notes are pinned to the inspected revisions, including older baselines; use the current application architecture when implementing the proposal.
