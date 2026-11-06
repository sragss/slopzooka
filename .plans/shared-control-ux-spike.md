# Shared-control UX spike: one preview, two agents, one user

Status: proposed subsequent UX exercise, November 1, 2026. **The latest user clarification prioritizes the [execution and presentation architecture](orchestrator-execution-path.md): how agent tool calls reach the Mac and open a live window on Vision. That supersedes the “immediate next” sequencing below.** The intended actors remain a Codex instance in the terminal and a global agent using computer use through the Mac companion. This document retains the narrower UX cases derived from the [discovery priorities](shared-window-live-results.md#remaining-feasibility-discovery-prioritized). Walkthrough wording remains proposed for user approval; nothing here claims the integration is implemented.

## Immediate scope correction after reviewing the implementation

The current probe's Vision `StreamPanel` displays video/images and has diagnostic buttons (resume, snapshots, AX inspection and resize). It has **no general remote pointer, touch or keyboard-input bridge**. The previous walkthrough's “user edits the draft” step therefore assumed additional implementation. Editing on the source Mac is a useful diagnostic perturbation, but is not evidence of direct user editing from Vision.

For the first pass, narrow the question to: **can the actual terminal Codex and companion global agent operate the exact streamed target, and can the user stop them reliably?** Build only the target/context and Stop path needed to answer that. Direct headset editing is an explicit follow-on capability; agent-directed input can be the initial UX. Do not label a paused video surface as fully interactive “You” control.

## The one question

**Can I watch an app, ask either agent to operate it, and take over without losing the app's state or wondering which window is receiving input?**

Use one existing workspace, its real terminal Codex instance, one already-running application, and one streamed Vision preview. Use two actual agent contexts: the companion's ephemeral global coordinator and the terminal Codex. They observe and act on the same application instance. Codex retains its ordinary coding/terminal workflow.

Run the experiment first with one managed Mac browser showing Poncho2's prompt input. Repeat the same interaction with one already-running iOS app's harmless draft field, using the proven device provider. These are two runs of the same interaction contract, one preview at a time. If a real iOS development build is not ready, a fixture can establish handoff mechanics, but must not be reported as a real-app integration pass.

Preselect/authorize the intended app before the trial. Starting projects, creating worktrees, browser authentication and preparing simulator builds happen during setup; the trial measures the shared-control UX. Keep the current native/JPEG transport for this experiment so a codec change cannot obscure the result.

## Proposed fuller walkthrough (direct-user-input step is conditional)

1. From the selected workspace's existing global-agent entry point: **“Show this app beside this terminal and put ‘handoff test’ in its draft. Don't send it.”** The coordinator attaches the already-selected app, presents that same target in Vision and uses CUA to enter the draft. The model discovers the input from observations; no registered app route or hardcoded selector is required.
2. **“I'll take over.”** The preview visibly switches to user control. The user changes the draft to any other text. Do not tell either agent the replacement text through a separate prompt; they must observe it.
3. In the existing terminal Codex: **“Look at this workspace's shared preview. Tell me what's in the draft, then append ‘ — reviewed’. Don't send it.”** Codex observes fresh state and acts on the same target through its granted computer-use tools. The user sees the edit in the existing preview. No new tab, browser profile, simulator or screenshot-only substitute counts as a pass.
4. During one agent interaction, use **Take over / Stop**, then ask the global agent: **“Continue from what's there.”** New agent input stops after takeover; continuation uses a fresh observation and an explicit control transition. Already-dispatched OS input may finish; measure and report that boundary rather than promise rollback.

Use a field whose content can remain an unsent draft throughout. No checkout, account change or external submission is needed. The iOS repeat uses equivalent wording for its actual field.

One adversarial replay is enough for this slice: invoke the menu/change focus while a request is pending, and confirm the request stays bound to the original preview. A similarly titled ungranted window can be present as a decoy, without adding another worktree or controller.

## Visible UX being evaluated

Only three additions are needed:

- The preview identifies its workspace/application; the global composer shows the captured target for “this.” Opening the wrist/menu must not silently retarget an utterance.
- A small controller indicator: **Paused / Global agent / Codex** for the first pass. Show **You** only if a direct human-input path is actually implemented. Observation alone does not take control.
- A **Take over / Stop** action that revokes agent input on that surface. Human takeover wins; an agent refreshes observation before continuing.

Use supported initial placement, or arrange the single pair during setup. This experiment does not establish arbitrary spatial rearrangement or linked group movement. Actual placement-instance discovery remains a separate small spike.

## Shared implementation boundary

```text
Global coordinator ── direct tool adapter ─┐
                                          ├─ companion-owned target/control provider ─ app
Terminal Codex ── scoped MCP/CUA adapter ───┘                    │
                                                        existing stream
                                                               │
                                                          Vision preview
```

The companion remains the execution/ownership boundary. Reuse the same provider implementation and existing workspace/window services for both callers. A thin MCP adapter changes how Codex reaches that provider, not which browser or simulator it controls. Capture and control may use different APIs, but their identities must resolve to the same app target.

The minimal shared state is: workspace-to-target association, provider-native identity (browser/profile/page or simulator UDID/app), target generation, current controller, and input generation. Keep control ownership in memory. The agent's reasoning can also be ephemeral; restarting it does not create a replacement browser or simulator. Use existing application records rather than introducing another workspace database.

The adapter needs only enough capability to resolve the workspace's shared target, attach/present it, observe it, perform the existing CUA actions, and acquire/release control. These are responsibilities, not a frozen new tool catalog or a universal action-language specification. Caller identity/scope comes from the connection/session, not an actor name invented by the model.

CUA supplies screenshots/semantic observations and input primitives. Application lifecycle still uses the existing explicit workspace/session/window operations. Deliver tasks to the terminal through its normal prompt/input path; do not drive the terminal's UI with desktop clicks to simulate task delivery.

Both controllers must pass their app input through the shared boundary for Stop/ownership to be enforceable. Before dispatch, validate the target and input generation. Reject stale calls after takeover rather than queueing them for surprise execution later. If a provider uses foreground mouse/keyboard input, serialize that focus-dependent work across the Mac; per-window handles alone do not provide independent desktop input channels.

## First technical gate: what “CUA” actually provides

Verify this before building the UX:

1. Launch the same Codex executable/configuration used by the SlopZooka PTY. Inspect its actual tool availability and establish a supported connection to the selected shared target.
2. Have Codex obtain a fresh observation and perform one harmless edit through the companion-bound provider. Have the companion reject the next edit after its input generation is revoked.
3. Confirm the global coordinator reaches that same provider, and the streamed target shows both results.

In the current source, `apps/mac-companion/src/sessions.ts` launches the configured `codex` command in a PTY; that code does not itself install computer-use tools. The CUA interface available in this conversation is evidence of this session's plugin tooling, not a public embeddable SDK contract for an arbitrary companion process or a guarantee of the fresh CLI's capabilities.

Official OpenAI documentation supports Codex CLI connections to external MCP servers over local STDIO or Streamable HTTP. It documents the packaged Computer Use feature through the desktop plugin, but the pages reviewed do not establish a public embedding/target-arbitration hook for that packaged backend. [Codex MCP connections](https://learn.chatgpt.com/docs/extend/mcp), [Computer Use](https://learn.chatgpt.com/docs/computer-use).

Prefer attaching an existing supported CUA provider. If its packaged tool cannot route through or honor the companion's input ownership, expose the small existing host/browser/device primitives through the scoped MCP adapter. Do not create a second automation stack or claim a cooperative “please stop” message enforces exclusion over an independent CUA path. Pause the integration decision at this specific dependency if it cannot be connected narrowly.

The Computer Use documentation also describes an opt-in desktop locked-use mechanism implemented with an Apple authorization plug-in. It is scoped to trusted active ChatGPT computer-use turns and is explicitly not a general facility for other local processes. It was not enabled or exercised in our probe, and does not establish that the companion or terminal CLI can reuse it. Preserve the independently tested simulator fallback; keep generic locked desktop control outside this UX slice. [Locked-use documentation](https://learn.chatgpt.com/docs/computer-use#locked-use).

## Fuller handoff finish line (after direct human input exists)

A successful browser run and iOS repeat must show:

1. The same app instance and unsent draft survive Global → You → Codex → Global transitions.
2. Codex correctly observes the user's undisclosed edit, and its edit appears in the existing Vision preview.
3. Takeover blocks subsequent stale agent actions; menu/focus changes do not redirect a pending request.
4. The user can identify the current target/controller and resume without technical setup or opening another app session.
5. We record takeover delay, action-to-visible delay, wrong-target effects, lost/duplicated text and user confusion. Zero wrong-target effects and no unintended submission are required; responsiveness is measured and judged with the user rather than declared from source fps.

Stop adding features when that question is answered. The outcome should select the target indicator, handoff behavior and minimal shared provider interface. It need not complete cold startup, multiple workspace launch, spatial clustering, media replacement, a new speech stack or a durable coordinator. Reuse the existing voice path if available; typed prompts through the same target-aware global entry point can isolate the handoff mechanics, but a voice-routing claim requires a subsequent actual voice pass.

Next implementation deliverables: one reusable control boundary with two thin caller adapters, the three visible affordances above, and a short evidence record for these conversations. Implementation remains subject to the CUA attachment gate; the larger prompt catalog remains unapproved.


## Risk-first test sequence

This sequence is the immediate next experiment. It supersedes the fuller walkthrough as a requirement for the first slice. Tests are proposed; none of these dual-agent integration claims was established by the media probe.

| Risk | Test that can falsify the design | Required evidence / decision |
| --- | --- | --- |
| **R1 — CUA is not reusable in the intended two processes.** A fresh terminal CLI and an independent companion coordinator may not have the packaged tooling available in this conversation, or may not expose routing/cancellation hooks. | Launch the actual configured terminal Codex and the actual companion agent. Each obtains a fresh observation and performs one harmless app edit using the intended supported provider route. Revoke that route's input authorization and attempt another edit. | Actual tool call/result, provider identity and changed app state for both actors; subsequent input rejection. If one route bypasses the companion, do not claim Stop covers it. Resolve this before building handoff UI or assuming a small embeddable SDK exists. |
| **R2 — The controlled app differs from the streamed target, or focus changes redirect input.** Same URL/title does not establish the same browser/profile/tab/device/build. | Keep the shared window and a similar unshared window open with different draft markers. Alternate agents, open the wrist/menu or focus the decoy while a request is pending, and perform an edit. Close/recreate the selected target once. | Only the granted target changes; the existing Vision stream shows the change. The decoy and its draft remain untouched. A closed/replaced target requires fresh resolution, never silent reuse of an old handle. No second worktree is needed. |
| **R3 — Input interleaves or keeps arriving after Stop.** A tool call may contain multiple input steps, or a native provider may use host-global focus. | Deliberately overlap two short editing requests; press Stop during a multi-step action; deliver a previously prepared delayed action after Stop. Include at least one real focus-dependent input path rather than only direct semantic field assignment. | A known controller's actions execute; competing input is rejected/deferred visibly. Revoked actions do not execute later. Record time of Stop, last already-dispatched input and rejected subsequent calls. If provider cancellation is coarse, expose that fact and bound action batches; a badge alone is not a solution. |
| **R4 — Observation is stale or control breaks on real UI geometry.** UI elements can refer to a wrapper instead of the switch; keyboard, scrolling, resize and rotation alter the target. | Have the first agent leave a draft; let the independent second agent read it without receiving its text in the handoff. Introduce one layout change, then request a field edit and a button/switch action. For iOS include keyboard appearance or rotation. | Fresh observation identifies the field and exact draft; the user sees the intended result. Failure causes reobservation or a precise error. Do not treat a tool acknowledgement or coordinate from an old image as proof. The earlier toggle failure is a concrete example of this risk. |
| **R5 — The complete loop is too slow or confusing despite a smooth stream.** Model observation/action time and delayed input can dominate transport fps. | Run a simple natural request (navigate, read draft, make reversible edit) through each real agent while the user watches; interrupt once. Use typed input first if needed to isolate control mechanics, then the existing voice path before claiming voice-routing success. | Measure command-to-first-visible-action, action-to-visible-result and Stop-to-last-input. Record target/controller confusion and required manual corrections. Source fps and a scripted direct-driver call are insufficient evidence of agent UX. |

### Smallest execution order

1. **Compatibility smoke check:** R1 with one app. No new presentation polish, workflow engine or custom CUA runtime. Stop expanding if the provider route cannot be connected narrowly.
2. **One browser exercise:** R2–R5 with one existing workspace, one terminal Codex, one companion coordinator and one streamed target; a second unshared window is only a decoy. Agents take turns reading/editing an unsent draft. The user observes and uses Stop. A source-Mac manual edit may test freshness but is labeled as a diagnostic, not headset takeover.
3. **One simulator repeat:** same contract, same adapters at the shared boundary, actual device provider underneath. Keep the simulator running and Mac unlocked for this first control test. The already-proven locked device path does not establish that a different CUA backend works while locked.

Direct Vision interaction gets its own narrowly bounded test only if it is included in the intended first UX: click the streamed field from the headset, enter text using the intended keyboard/dictation path, and repeat after resizing the panel and showing the iOS keyboard. Pass only when this works without reaching for the Mac. This requires an input-return path and coordinate/focus mapping; video streaming alone supplies neither.

The immediate pass is zero wrong-target edits, no unintended submission, preserved draft state, explicit rejection of stale/competing actions, and user-acceptable observed response/Stop times. It establishes the supported provider routes tested, not exclusion over every independent automation program on the machine. Cold simulator startup, spatial clustering and media efficiency remain separate discovery decisions.
