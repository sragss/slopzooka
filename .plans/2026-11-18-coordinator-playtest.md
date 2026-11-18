# Coordinator headset playtest

Live feedback for the November 18 slot. The headset runs the isolated routing build
from draft PR #65. Collect and verify changes locally during play. The operator subsequently requested a reboot after the batch passes.

| Item | Status | Acceptance |
| --- | --- | --- |
| Remove the companion name from the normal Ask header | Implemented | On the connected Mac, show just Global or the terminal context. Keep enough information to recognize and correct a different destination. |
| Worker model selection | Verified on live workers | The rig explicitly passed gpt-5.6-sol at thread creation. Qualify the requested gpt-6.2-sol on the replacement workers and keep the Pi model independent. |
| Voice project names | Implemented | Include short host-scoped launcher vocabulary so the model can map spoken near-matches and clarify ambiguity. |
| Explain failures | Implemented | Distinguish request failure, worker failure, uncertain delivery and unavailable agent. Keep the actual cause visible on the affected exchange. |
| Speak again while Ask is working | Implemented | A second and third utterance can be spoken and acknowledged in order while Pi works. Capture each destination and request ID when spoken. |
| Stop control | Implemented | Show an icon-only Stop directly above the bottom-aligned right-edge mic during active work, using the same geometry as the mic. Hide it at rest. |
| Mic ornament | Implemented locally | User selected the right edge. Preserve the 120-point hit target and let chat fill the bottom of the panel. |
| Find existing Codex threads | Implemented | Page through the local Codex catalog or search by topic, then peek into short user/assistant excerpts. No resume, input or full transcript. |
| Resizable Ask window | Implemented locally | Opens at 520 × 560 and allows independent horizontal and vertical resize above a readable minimum. |
| Activity inside the chat | Implemented locally | The spinner and live activity text are attached to the active exchange, including when later speech is queued. |
| Conversation edge | Implemented | Fade older content into the top edge while scrolling and keep the first message readable at the top. |
| Two independent Codex workers | Implemented | Two workspaces can run coding tasks and have separate terminals and threads. An idle worker cannot reserve native input for its whole lifetime. Define and test overlapping requests for foreground input separately. |
| Preview selection | Verified on Mac | A request for “login check” cannot present the macOS login process. With no matching user window, the model asks which source to show or reports it unavailable. A preview rename operates on the existing layout record. |
| Correct destination and trace | Verified on the routing build | All four original requests went to the previous test companion. A clean test app and isolated host subsequently returned a count of two, and the terminal rename was independently read back. Native and Mac events now correlate destination, tool and saved window ID. |
| Foreground clears unread | Passed on headset | The operator confirmed notification clearing with the bell fixture. Its ordinary shell was intentional. A separate real Codex worker is running in Sam-Dash-test. |
| Launcher pointer lag | Pending observation | Compare pairing and connected surfaces with the shared Mac pointer. No performance verdict from this slot yet. |

The first worker finished before the test service was replaced. Two separate worktrees then started real Codex threads on `gpt-6.2-sol`. The Mac recorded both thread IDs and selected models. The user subsequently ran additional Poncho workers in parallel. The native-input contention test used disposable MCP clients. Two real native runtimes initialized and listed tools; simultaneous foreground manipulation was not part of that test.

A live Ask exchange requested a standalone email client. Ask first requested a parent project and then repeated that requirement when asked to make a new project. The old tool could create only a worktree from an existing GitHub repo. The new tool creates a local repo and its first worktree in one operation using the existing Mac index. Pi accepts “new project” as an alias. The launcher defaults to local creation too. The explicit GitHub creation path remains available. A disposable live Pi run returned “Created the local repo **email-test** and its first worktree.” Git reported zero remotes, and submitting the same request ID again left exactly one worktree. The HTTP regression also created a second branch and reopened the original worktree. All 90 companion tests passed on rerun after one transport fixture timed out on the first run.

The right-side ornament now uses one shared glass button for both actions. The mic stays at the bottom when Stop appears above it. The operator has yet to assess the stacked ornament and web-preview ownership label in the headset. Mac source captures have no canonical worktree association. Web previews can display the ownership found by the existing local listener directory match.

Thread discovery and bounded excerpt retrieval were exercised against the installed Codex app-server. Catalog pagination returned distinct pages; topic search returned candidates, and a known thread returned three bounded exchanges with no command output. The user confirmed the earlier headset notification and window-name checks. Shared-pointer lag remains open.

A live Pi handoff probe used a disposable worker endpoint to inspect the task that Codex would receive. A request to check settings reducer tests carried no preview guidance. A follow-up asking the same worker to show Poncho2 Settings on the headset named the iPhone Simulator, the requested screen, the paired preview MCP and the matching source to open. This verified the handoff text separately from headset presentation.

The next device build tracks the pinch that started Ask dictation. Previously the mic used the SwiftUI button’s visual pressed state as its release signal. The speech controller already restricted silence-based submission to naming. The state check spans two recognition segments during one hold. Physical gaze-away behavior needs a headset verdict.

The WooCommerce exchange exposed a gap between the launcher's saved-thread resume action and Ask’s search/peek tools. After reboot, live Pi found and opened “Review Hark and Granola notes” in woo-demo through the existing resume route. The returned session was running with the original Codex thread ID in the current headset layout. All five previously running terminals survived the HTTP companion update.

End Session releases session-owned previews across paired client layouts. A separate test client on the rebooted host ended a disposable shell and verified that its preview disappeared while an independent preview remained. Regression checks also verified a shared preview remains for its other owner, retries are idempotent, and a stale open cannot recreate the ended session's preview.

### Follow-up checks from the November 18 evening slot

- Trace the two production-telemetry follow-ups on Slow submit investigation from Ask acknowledgement to their actual Codex turns.
- Share Ask’s pinch ownership with the terminal and agent mics. Allow a second pinch during the send countdown to append to the original draft.
- Investigate the missing terminal notifications, including what the coordinated Codex TUI emits and how the headset receives and acknowledges it.

At 18:43 EST, Ask had two successful worker submissions for Slow submit investigation. A read-only native Codex queue listing matched both delivery IDs on the correct thread. Its history still contained only the original in-progress turn. In a separate run with the installed Codex binary, a queued message automatically became a second turn after the first completed. The UI incorrectly used “Agent working…” for both states. The fix gives Pi a per-message receipt and the headset a distinct waiting label. Guidance directs corrections to the active turn and reserves the queue for subsequent work.

Both the investigation terminal and a completed email worker had a PTY notification sequence of zero at 18:47 EST. Both had another viewer attached. That rules out a headset badge clearing the only emitted alert for those sessions. The previous headset bell check established the explicit bell path independently.

A disposable end-to-end run sent a correction through real Pi while a real Codex worker was active. The receipt matched the initial turn ID and the final answer changed from the requested ORCHID to VIOLET. In the same run, the TUI enabled DEC focus reporting, received focus-out, and emitted one terminal notification. The staged builds record the writer’s focus reports and the headset’s unread and read transitions. The next headset check is a worker completion after switching to Ask. Capture the focus report, PTY counter and headset acknowledgement together.

State checks exercise both terminal and Ask dictation through final transcription, re-grabbing during the grace period, waking a cancelled timer, and an OS-cancelled pinch. Each test delivered one combined message to its originating window. Physical gaze-away and re-grab still need confirmation.
