# Existing terminal worker delivery: results

November 10, 2026. **A separate controller can operate the same Codex thread shown by a real terminal TUI, using an explicitly owned App Server.** Idle delivery, native queueing, turn-specific steering, interruption, reconnect/reconciliation and a native permission wait were exercised. This qualifies the owned launch arrangement; it does not establish attachment to every independently launched personal Codex process.

The final complete run was `run-vXdNaG`, 09:40:20–09:41:50 America/New_York. Earlier partial runs and startup failures are retained. [Reproduction](../experiments/worker-delivery-probe/README.md) · [Sanitized evidence and hashes](evidence/2026-11-10-worker-delivery/results.json) · [Previous execution plan](2026-11-09-post-cleanup-execution-plan.md).

## Arrangement tested

- Codex CLI **0.167.0**, `gpt-6.1-sol`, low reasoning effort, existing ChatGPT login. A private temporary copy of the file-backed login was removed afterward. This is local account-use evidence, not a commercial distribution or billing qualification.
- The real SlopZooka session service created and owned a disposable PTY. It ran the normal Codex TUI with `--remote unix://…` against one separately owned App Server. Another Unix-socket WebSocket client initialized and joined that exact runtime/thread. The agent loop and terminal renderer remained Codex's.
- The first bootstrap used ordinary terminal input. Every measured external task then used the structured API or `codex queue`; none was pasted into the terminal composer. The bootstrap message in native history established the binding. Listing one loaded thread or matching a working directory is insufficient.
- Model tasks used only a disposable MCP ledger, controlled wait gates and form elicitation. Shell, web search, apps and plugins were disabled for the experiment. An independent effect log and native events established outcomes; terminal output additionally confirmed the externally submitted idle result appeared in the TUI. No production browser, simulator, code-editing workflow or headset was exercised.

OpenAI documents remote TUI connection, `thread/resume`, `turn/steer`, `turn/interrupt`, history and native approval requests. Its schema generator provides the exact interface for an installed version. [Official App Server documentation](https://learn.chatgpt.com/docs/app-server).

The measured stable schema has 106 client methods and **no queue methods**. With experimental output enabled, it has 180 methods, including `thread/queue/add`, `list`, `update`, `delete`, `reorder` and `start`. Queue integration therefore requires explicit version/capability qualification. The CLI's public `queue` command also worked, but its concise receipt alone does not establish task completion.

## Case ledger

| Case | Result | Evidence / limit |
| --- | --- | --- |
| Join an existing TUI worker | Passed in owned arrangement | The controller joined the thread containing the TUI's actual bootstrap message; it retained that native ID for all tasks. No second reasoning runtime was launched to resume its history. |
| Idle external submission | Passed | One `turn/start`, one independent `idle` effect, native completion and `IDLE-DONE` in TUI output. Ordinary product submissions should use the qualified queue path. |
| Queue while busy | Passed | Requests stayed pending while a tool gate held the active turn, then drained automatically after it completed. Native queue state and independent effects agree. No application task scheduler was added. |
| Steer the intended active turn | Passed | Wrong `expectedTurnId` was rejected. Correct steering returned the current turn ID and changed the post-gate effect to `steered`; `busy-done` did not occur. |
| Duplicate submission protection | **Native guarantee absent** | Repeating identical input with the same `clientUserMessageId` created another queued submission and executed `queued` twice. Reusing that ID with changed text created a third submission and executed the changed task. The field is correlation, not an idempotency key in this build. |
| CLI queue against live worker | Passed | `codex queue --remote … --thread UUID --message …` returned a native queued-submission ID; the same worker produced exactly one independent `cli-queued` effect. |
| Lost acceptance reply and reconnect | Passed for injected response loss | The adapter discarded the acceptance response and disconnected. A fresh connection rejoined the still-active thread and found exactly one pending entry by `clientUserMessageId`. It did **not resubmit**. The eventual effect occurred once; persisted `userMessage.clientId` retained the correlation after the queue drained. |
| Stop active turn | Passed within fixture scope | `turn/interrupt` acknowledged in about **5.5 ms** in the final run and emitted `interrupted`; the forbidden post-gate effect did not happen. This is one local control measurement, not an end-to-end input cancellation SLA. |
| Stop versus queued follow-up | Separate scopes confirmed | The follow-up remained queued and did not execute during the observation. The operator then explicitly deleted it. Interruption did not empty the queue. |
| Permission/user-input wait | Passed for MCP elicitation | A real `mcpServer/elicitation/request` produced `activeFlags: [waitingOnApproval]`. No consent effect occurred before the authorized fixture answer; one occurred afterward. OS TCC grants and shell escalation were not tested. |
| Exit TUI into shell | Lifetime distinction confirmed | Ctrl-D ended the TUI; the production session service retained its running shell. The independently owned backend/thread remained available. Stale steering failed because no turn was active. No task text was sent into the shell. |

The exit test does **not** prove that a retained worker must be rejected merely because its TUI closed. In this arrangement, the TUI is a client and the backend is the worker owner. Nor does a running PTY prove the worker exists. Product policy must explicitly distinguish UI detachment, ending coding work, and ending the terminal session. The recorded 1.2-second observation after controller unsubscribe is not a guarantee of indefinite retention or a measurement of the unload grace period.

## Failures that affected the test design

The initial `app-server proxy --sock` path timed out during initialization against this explicit listener. Direct WebSocket over the same private Unix socket worked. This is a failed attempt, not proof that all proxy configurations are broken.

Early startup inspection could see a loaded thread before its rollout was ready. A remote TUI also exposed an empty placeholder thread; history queries against that placeholder returned `thread/items/list is not supported yet`. The final runner waits for the bootstrap's independent effect and binds only the thread whose actual native history contains that message. Production should establish the native ID as part of owned launch/attachment, not reproduce the fixture's history search or select the first loaded thread. These failures and the earlier partial successful runs remain in the evidence manifest.

## Changes to the execution plan

1. **Use an owned Codex runtime with terminal and control clients for the initial integration.** This keeps the terminal UI and the real harness while providing structured control. Bind the SlopZooka session/workspace to a native thread ID and runtime incarnation through the existing Mac session owner. A new App Server pointing at saved history is not equivalent to joining a currently running worker. Adoption of arbitrary pre-existing TUIs is a separate capability.
2. **Keep the queue in Codex; add bounded delivery correlation at the existing owner.** Serialize duplicate application request IDs, compare their payloads, and retain their native submission/turn references. On uncertain delivery, query native queue and history before any retry. Absence from one query does not prove a delayed request failed; preserve `uncertain` when reconciliation cannot establish the outcome. The native queue does not justify blind retries or a second durable scheduler in Pi.
3. **Expose Stop truthfully.** Revoke shared-target input first where applicable, then interrupt the specified native turn. Report whether queued work remains; clearing selected queued work is a separate operation. Do not claim to undo already-dispatched UI effects. The fixture's cancelled reasoning task is not a substitute for provider-level input revocation.
4. **Track worker lifetime independently of the TUI/shell.** Explicitly bind/detach/end the worker. Never fall back to PTY text when a binding is missing or stale. A UI exit should have an intentional background-worker policy rather than an inference from `SessionSummary.status`.
5. **Proceed to manual stream integration and capture-lifetime separation.** The core delivery mechanism is now demonstrated. Connect ephemeral Pi to this small adapter after frontend/preview integration; the worker still calls scoped target MCP directly. A production task combining Pi, that bound worker and the exact displayed target remains the integration acceptance case.

No additional broad headset discovery is needed before starting that work. The small direct-Pi navigation exception remains a UX question: the wait-gate tests establish ordering and steering, not the experience of navigating a real app while its coding worker is busy. Real workspace setup, full user configuration parity, voice, arbitrary native apps, runtime upgrades and helper/host restart recovery retain their own scope and checks. This test did not choose a permanent Pi memory store, a new conversation UI or a generic multi-provider framework.

## Verification and cleanup

The final full sequence completed, with native duplicate behavior explicitly classified rather than hidden under an all-green product claim. The two earlier successful partial sequences corroborate the delivery and recovery outcomes. Raw logs, local schemas, account metadata and terminal output remain ignored; committed evidence contains sanitized observations and hashes.

All owned session services/backends were stopped, copied credentials removed, and a final process audit found no remaining processes tied to any test temporary directory. The regular SlopZooka app, its PTYs and normal Codex daemon were untouched.

Required repository checks also passed: 51 companion tests, native state checks, typecheck, terminal keyboard/preview tests, formatting, harness regeneration without extra asset changes, and a visionOS simulator build. New probe sources passed formatting/syntax checks. No production application source changed and no physical-device run occurred.
