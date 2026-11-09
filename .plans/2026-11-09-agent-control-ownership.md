# Open decision: which agent owns computer use?

Status: unresolved, November 9, 2026. Resolve the initial responsibility split before implementing the agent integration. Earlier plans assumed direct global-Pi computer use; that is now one candidate, not a requirement. This note updates the [tool layout](orchestrator-tools.md) and [execution/rollout plan](orchestrator-execution-path.md).

## Separate execution from reasoning

Two decisions were getting conflated:

- **Where commands execute:** Mac-owned providers control the actual browser, native window or simulator. Existing workspace/session services own resources; Vision's `WindowGateway` owns presentation. Streaming and target identity should work independently of which model requested an action.
- **Who decides the next action:** the workspace's terminal Codex agent, the global Pi agent, or either under a clear task assignment. This remains open. Sharing an implementation does not require granting every agent the same tools or context.

The minimum global role under discussion is contextual command/prompt routing, project/workspace discovery and naming, and window/session launch and presentation. Interpreting “send this to the other workspace” does not necessarily require the global model to inspect that application's DOM or choose its clicks. Conversely, knowing which window is selected does not give Pi the coding agent's knowledge of the change being verified.

“Window-level agent” means the coding session associated with a workspace, not a process owned by a Vision scene. One session may use multiple previews; closing a preview does not terminate its agent or app.

## Alternatives to compare

| Option | Responsibility | Why it might work well | Cost or uncertainty |
| --- | --- | --- | --- |
| **Coding agents own CUA** | Pi routes requests and manages workspace/window intent. The relevant Codex session observes and operates its granted targets through MCP. | Code changes, logs, repository instructions and UI verification stay in one reasoning context. Pi remains small. | Navigation before a coding session exists, an already busy agent, and cross-workspace requests need an explicit path. A quick voice action may wait behind coding work or disturb its context. |
| **Global Pi owns CUA** | Pi performs app navigation and interaction; coding agents request UI work and receive observations/results. | A consistent conversational actor can act on what the user is viewing, including apps unrelated to an active coding task. | Pi may need substantial task context to verify a change. Repeated coder→Pi→coder exchanges could add latency and lose important observations. A single global loop could become a bottleneck. |
| **Both can own a task** | Both receive the relevant capability; one actor owns an interaction until completion, interruption or explicit handoff. | Codex can verify its work directly, while Pi can handle immediate navigation and workspace preparation. | Routing, competing requests and handoff introduce behavior to maintain and explain. Shared access alone does not settle who should act. |

These are hypotheses, not measured rankings. Native foreground-dependent input can contend across windows in every option; two independent agents do not create two Mac keyboards. Target-specific browser/device input may allow more concurrency, but model responsibility and provider concurrency remain separate decisions.

## Prompts that expose the difference

The following are candidate comparisons for user review, not newly approved workflows:

| Prompt or situation | Question to answer |
| --- | --- |
| “Fix the settings bug and show me it working.” | Does direct Codex verification preserve useful context and avoid a second agent reconstructing the task? |
| “On this screen, open account settings.” | Can routing to Codex feel immediate, including while it is building or editing? Does Pi need direct CUA for this to feel good? |
| “Launch Poncho2 in a new worktree, with admin and iOS open; leave iOS on Settings.” | Who discovers setup and navigates before a coding task exists? Can a newly launched Codex session prepare the UI without requiring the user to invent a code-edit task? |
| “Put these two workspaces on the same screen so I can compare them.” | Does Pi navigate both, or coordinate a bounded task for each owner? What context actually needs to cross that boundary? |
| “Stop. Let me log in, then continue.” | Which task pauses, who resumes, and can either agent act on stale observations after the human changes the screen? |
| “Send `/review` to the left terminal,” versus “type `/review` into this app's search box.” | Can prompt routing distinguish terminal commands, dictation and app interaction without making the global agent the mandatory UI operator? |

Selection is context, not an automatic transfer of task ownership. Looking at another window should not redirect an in-progress verification task. A fresh user request can target the newly selected window; that does not silently retarget earlier actions.

## Keep either choice inexpensive to change

Preserve one shared provider implementation and the existing resource owners. Pi tools and coding-agent MCP can be thin adapters with different grants; avoid an agent-specific capture or window-lifecycle path. If Codex owns the interaction, its observation/action loop should call the provider directly. Pi need not relay every click or re-reason over every screenshot.

If delegation is selected, transfer a bounded goal, exact target/workspace identity, relevant constraints, and a result or status reference. The receiving agent obtains a fresh observation. Do not synchronize entire conversations or add a permanent supervisor/worker dialogue for routine navigation. The actual terminal-agent submission, busy-state and interruption interface still needs qualification; writing arbitrary text into xterm is not a demonstrated structured task API.

If both agents receive CUA, begin with one visible controlling actor and provider-enforced input admission/Stop. Ownership can be ephemeral. A user correction must invalidate stale queued actions regardless of which model produced them. Any current native-input arbitration is shared Mac state, not another durable agent database.

Provider choice remains independent: preferring the installed Codex runtime does not imply that a terminal Codex model must own every interaction. Its reuse constraints and browser authorization limitations still apply to whichever adapter invokes it. See the [runtime experiment](2026-11-08-codex-runtime-reuse.md), [browser investigation](2026-11-09-browser-runtime-options.md) and [guidance audit](2026-11-08-codex-browser-and-guidance.md#november-9-audit-desktop-runtime-versus-cli-itself).

## Decision before implementation

First walk through these cases and choose the prompts to evaluate with the user. Then compare direct Codex and direct Pi control against the same prepared browser/simulator and shared provider boundary in a disposable spike. If delegation remains a candidate, exercise the real agent submission/result path as well; a manually forwarded prompt does not establish its UX. Production rollout should implement the chosen initial split, not three complete orchestration systems.

Record time to first useful visible action, verified completion, model handoffs, context the user had to repeat, behavior while Codex is busy, and Stop/target correctness. Test ordinary navigation as well as code verification. Prior streaming and runtime experiments establish useful provider feasibility; they do not answer this responsibility question.

The working hypothesis worth testing is **Codex verifies the code it is changing; Pi handles immediate navigation and workspace setup**. That is a candidate for the shared-access option, not a fixed routing rule or an approved architecture. Prefer the smallest responsibility split that satisfies the approved prompts. If coding-agent-only control handles them comfortably, direct Pi CUA may be unnecessary; if frequent handoffs make it cumbersome, that is evidence for broader global control.
