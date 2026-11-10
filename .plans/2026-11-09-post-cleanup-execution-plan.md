# Execution plan after the companion/window cleanup

November 9, 2026. Reviewed after merging upstream `main` through `6d7d26d` into this research branch (`cdd38a5`). Upstream's default branch is `main`, rather than `master`. This updates implementation ordering; it does not claim another physical test. The [physical results](2026-11-09-surface-live-results.md) retain their original tested revision and limits.

**Start implementation on the existing owners. No preliminary window/networking rearchitecture is needed.** The cleanup supplies the shared native client, per-window state and naming operations we wanted. The worker-delivery experiment proposed below was completed on November 10 for an explicitly owned Codex runtime and real terminal TUI. [Results and limitations](2026-11-10-worker-delivery-results.md). Further streaming checks mostly belong with the production integration and supported-feature qualification.

## What the merge removes from our work

| Existing implementation | Effect on this plan | Remaining addition |
| --- | --- | --- |
| [`CompanionClient.swift`](../apps/vision-client/SlopZooka/SlopZooka/CompanionClient.swift) owns discovery, accepted host routes, pairing, authenticated typed requests, connection state and polling. Route revisions reject replies from superseded connections, including changes back to the same address. | Extend this client for native presentation/context calls. Delete the earlier prerequisite for another connection manager or a mandatory `/ws/control` socket. | A bounded command/context/receipt contract for an explicit paired client. Choose polling, long polling or push within this owner when measured latency requires it. |
| One frontend catalog and poll per accepted Mac; views observe the client. | Stream sources can appear through the existing frontend flow. No per-preview discovery timer or agent-maintained copy of the menu. | Generalize the Mac catalog and Swift payload to represent a stream source honestly; current frontend fields still assume web resources. |
| [`WindowGateway.swift`](../apps/vision-client/SlopZooka/SlopZooka/WindowGateway.swift) keeps one ephemeral `WindowState` per ID. Reload revisions version resolution; replacement work starts without waiting for old work, and late replies cannot replace new content. | Attach stream content and receiver status here. Reuse normal open/close/reload and the existing persistence/outbox. | Provider binding, stream content state and aspect-ratio hints. Capture subscriptions remain provider-owned; desired layout remains unchanged in purpose. |
| [`LauncherState.swift`](../apps/vision-client/SlopZooka/SlopZooka/LauncherState.swift) has shared operation/catalog handling; Mac services already own workspace and session mutations. | Keep UI busy/selection state in the launcher. Pi calls the existing Mac owners. | Share launch/retry semantics only where the second caller demonstrates duplication; preserve completed workspace/session IDs after partial failures. |
| [`WorkspaceService.renameWorkspace` and `describeSessions`](../apps/mac-companion/src/workspace.ts), the workspace PATCH route and session naming already persist/display project, workspace and window labels. | Automatic agent naming is now a caller of existing metadata operations. No new naming service or coordinator database. | Generate useful names from task context and protect explicit human names from delayed/automatic updates. Current normalization/default labels do not implement that policy. |
| Native checks inject an HTTP exchange into the real `CompanionClient`. | Test real request bodies, decoding, credentials, route changes and gateway behavior using one controllable transport. | Add production stream/delegation fixtures to this seam; avoid a second sandbox application or a fake copy of the client. |

`CompanionClient` is a **Vision-side client**, not a service Pi imports into the Mac. Pi calls Mac domain handlers; the headset client reaches those handlers through the paired protocol. The client does not own Mac processes, media production, coding-agent state or reasoning. Existing terminal WebSockets, preview WebView networking and bulk stream transport retain their separate jobs.

Route identity is not authentication. The new Keychain host identity and trusted-origin bindings should be reused, not bypassed by accepting a model/discovery-provided endpoint with a matching host ID. Media still needs its temporary, exact-target grant and transport trust; sharing the control client does not automatically secure an unrelated media listener.

## What was adapted in this merge

The three conflicts were in `WindowGateway.swift`, its tests and the native test runner. The optional probe now polls/resolves through typed `CompanionClient` methods. Receiver status lives in the existing window state record; probe command receipts remain bounded experiment state. It no longer retains the removed `CompanionAPI`, endpoint map or parallel window-presence map. Both upstream and probe checks were retained.

A new regression drives a real probe poll through the injected HTTP exchange, checks its body/status reporting, then replaces the accepted route while a poll is delayed. The old batch is rejected even when the accepted address is unchanged. Existing explicit-close, duplicate, late-resolution, restoration and no-extra-session checks still pass. This is automated integration evidence, not a rerun on the headset.

## Worker-delivery experiment: completed for an owned Codex runtime

**Completed follow-up:** native delivery/queue/steer, reconnect, permission wait and interruption were demonstrated. The adapter must reconcile uncertain requests because native queue IDs do not deduplicate, distinguish queue clearing from interruption, and track worker lifetime independently of the TUI. Keep the queue in Codex. The original experiment outline follows for reproducibility; it is no longer a prerequisite research task.

**Use one disposable, real terminal Codex session and submit to that same live agent through a small external adapter.** This can run on the Mac without the Vision Pro. Keep its normal harness/authentication and terminal UI. The independent Pi and `codex exec` fixture runs proved tool usability; they did not prove attachment to an existing interactive session.

1. Establish the exact SlopZooka session, native agent identity and runtime incarnation. Deliver a bounded idle task and correlate native acceptance with an independent effect.
2. Keep that agent busy. Submit an ordinary queued task; then explicitly steer the current turn. Verify queue versus execution and whether steering is actually supported. Measure a short navigation/verification request while busy: this informs whether Pi needs a narrow direct-navigation exception.
3. Interrupt, exercise a permission/user-input wait, exit the agent into its shell, and lose a delivery reply. Reconcile outcomes before retrying; never type a task into the shell or silently start a replacement agent. Verify Stop does not rely on the model responding.

The decisive result is a supported same-session submission/status path, with honest capability limits. If the existing TUI cannot be attached/steered reliably, choose an owned launch/attachment adapter or limit the exposed delivery modes. That is a real implementation decision; recreating a durable queue in Pi or driving the desktop composer would conceal it. No new native conversation UI is required to learn this.

Generic native Mac control remains a separate conditional shipping gate: runtime packaging/support, clean permission attribution and helper/update recovery must be qualified before offering arbitrary Mac apps. It need not block the already-demonstrated simulator/browser paths. The hosted native CUA initialization failure in the physical slot remains evidence of that distinction.

## Revised execution sequence

| Step | Small deliverable | Acceptance that matters |
| --- | --- | --- |
| 1. Integrate the qualified worker adapter | Use the tested owned-runtime/TUI arrangement; add bounded request correlation, native queue/history reconciliation and explicit worker lifecycle binding at the existing Mac session owner. | Preserve the native-session/turn and queue/steer/status evidence; reject changed duplicate application requests, avoid blind retry, and distinguish UI exit from worker end. Actual Pi delegation remains the later integration case. |
| 2. Integrate one manual stream frontend | Register/attach a prepared simulator through the existing Mac frontend owner; shared catalog → Show → gateway → transient stream payload → existing Preview. Use the tested device provider first. | Works with Pi disabled, preserves stable IDs, restores without a launcher, distinguishes source loss from viewer disconnect, rejects stale actions/resolutions. Extend Swift/TypeScript wire fixtures together. |
| 3. Separate viewing from agent input | Provider owns source lifetime and temporary capture subscriptions; agent connections only own their scoped input authority. Bring the owned-browser path into the same preview flow. | Agent completion, input Stop or one viewer closing leaves another interested viewer alive. Last viewer release can pause capture without killing the source. Restart/reconnect reports accurate availability and rejects old bindings. |
| 4. Wire ephemeral Pi and scoped worker MCP | Capture host/client/workspace/worker/frontend context before menu focus changes. Pi invokes existing lifecycle, naming and presentation handlers and delivers a bounded task to the real worker. The worker calls the exact provider directly. | One typed request produces the verified change in the matching preview. Stop bypasses reasoning. Closing/resetting Pi does not own resource teardown. No screenshot/click relay through two reasoning loops. |
| 5. Exercise workspace preparation | “Launch Poncho2 in a new worktree, with admin and iOS open.” Let the worker discover project-specific setup. Name through the existing workspace API. | Correct worktree/page/device and useful label; fail one setup step, then resume without duplicating completed resources. Respect an explicit user rename. Two-workspace variation follows. |
| 6. Add the selected voice/wrist entry and qualify the supported experience | Reuse the same entry/context/receipts. Tune media and expose only qualified capabilities. | Real speech queue/steer/Stop and “the other workspace”; measured visible response, truthful errors, supported lock/recovery behavior. |

Steps 1 and 2 can proceed independently. No new window family, durable global coordinator, universal action language, Chromium embedder or model-specific media channel is needed for this sequence.

Keep the first command path on existing authenticated request/snapshot machinery. The probe currently polls in the session-refresh path; that proves a connection, not a low-latency SLA. Production presentation delivery must avoid blocking ordinary refresh during a stalled optional command request. If polling is too slow, extend `CompanionClient` with bounded long-poll/push delivery. **Immediate Stop and any future direct pointer/keyboard input must not wait for periodic polling or model inference.** Bulk frames bypass both the control queue and the model.

## Remaining tests, by the decision they answer

The [Codex thread-handoff investigation](2026-11-10-codex-thread-handoff.md) additionally establishes native catalog access on the existing shared server, including this active conversation. Plan a **Continue Codex thread** launcher action through the same worker/session adapter. Preserve the native thread and original cwd; attach to a known live runtime or explicitly resume saved history. Prefer a compatible existing shared runtime when available, while retaining the tested owned-runtime arrangement. Shared history alone does not establish safe live adoption. No additional conversation database or window owner is needed.

| Test | Timing / purpose |
| --- | --- |
| Existing-worker idle/busy/queue/steer/exit/lost-reply test | Completed for the owned Codex runtime. See the November 10 ledger. Arbitrary-TUI adoption, backend restart, and real-app navigation while the worker is busy remain separate qualifications. |
| Desktop / CLI / SlopZooka thread handoff | Native read-only discovery passed. Qualify one disposable persistent thread in both directions, with exact runtime/turn identity, original cwd, required tools and no duplicate worker. Test the inspected desktop deep link; keep different-runtime and missing-cwd behavior explicit. No headset required. |
| Capture survives agent completion and input Stop; two viewers release independently | Build with step 3 on the Mac. The current browser probe loses capture on caller exit; the ownership correction is already known. This verifies the correction, rather than reopening architecture discovery. |
| Short integrated headset check after the production slice | Prepared source, explicit close/reconnect with launcher closed, obvious per-stream identity marker, Stop with live viewing. Include the unresolved browser count comparison. This qualifies changed integration; do not repeat the whole original slot. |
| Real workspace launch with one partial failure | Step 5. Reveals setup/discovery and retry gaps; existing prepared fixtures cannot establish it. |
| Direct human input over the stream | Only if choosing it for the first release. One browser and simulator: click/type/scroll, resize/reconnect, decoy target untouched. Upstream terminal keyboard fixes do not forward input to remote apps. Semantic gaze/focus remains a later feature. |
| Codec quality, sustained stalls, navigation/resize, resource capacity, cold locked start, sleep/lid, high stream counts | Qualify only the capabilities we choose to promise. Keep the existing H.264 direction and recorded JPEG limitations; none requires another broad pre-implementation feasibility round. |

The phone-shaped default, somewhat jumpy JPEG animation and proposed attention-driven recovery under 500 ms remain recorded UX work. The attention target is unmeasured and does not establish an available gaze API. Precise spatial placement, browser embedding and indefinite away-from-Mac operation remain separate scope decisions.

## Verification of this merge

Passed: all 51 companion tests; native state/client/gateway/probe checks; typecheck; terminal keyboard/preview WebKit checks; formatting; harness regeneration with no extra asset changes; full visionOS simulator build. The new probe poll/route-replacement regression is included. Private command logs and their fingerprints are recorded in the [merge evidence](evidence/2026-11-09-post-cleanup/merge.json).

Pre-existing uncommitted research was backed up and verified unchanged by the merge. Subsequent plan edits are staged separately from that work. The physical record still describes the earlier signed builds; no fresh signed-device build or headset run was performed here.
