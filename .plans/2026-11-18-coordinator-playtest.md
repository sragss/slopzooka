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
