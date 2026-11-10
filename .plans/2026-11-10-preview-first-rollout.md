# Preview-first rollout, with terminal MCP before Pi

November 10, 2026. The user proposes shipping the new preview content first, adding a small MCP to coding terminals for opening/ending/naming previews, qualifying native Codex computer use, then adding Chrome control and finally the global Pi harness. **Adopt this sequence. We have enough feasibility evidence to begin implementation; the remaining checks belong to each production slice.** This supersedes the worker-adapter-first ordering in earlier drafts.

The initial product is useful without a global model, voice routing, external submission into Codex or a replacement terminal UI. A normal coding agent can launch/navigate its app with its existing tools and request that SlopZooka show the result. The preview MCP only exposes the companion's preview operations.

## What has been tested, and what has not

| Building block                                        | Evidence already obtained                                                                                                                                                                                                                                                                               | Remaining qualification for this rollout                                                                                                                                                                                                                                           |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native Mac windows streamed to Vision                 | Native fixture, Chrome window and Simulator window were independently visible through ScreenCaptureKit → hardware H.264 → native Vision rendering. User-observed recovery after unlock. [Physical streaming results](shared-window-live-results.md).                                                    | Move the selected pieces into the actual signed companion/Preview lifecycle; qualify permission setup, exact window binding, stalls, reconnect and receiver freshness. The isolated probe is not the production implementation.                                                    |
| Presentation through the actual SlopZooka gateway     | Prepared simulator opened, closed, reopened and remained controllable with the launcher closed; terminal Codex changed the streamed simulator after Pi. [Gateway results](2026-11-09-surface-live-results.md).                                                                                          | General stream schema and lifecycle, production catalog/resolve path, phone aspect ratio, new-source preparation and automatic bounded recovery. That device used WDA/Appium; it was not a native-CUA-to-Simulator test.                                                           |
| Native Codex Mac CUA runtime                          | Independent model-driven native fixture operation; native cold start with ChatGPT closed; helper recovery and bounded cancellation. [Runtime qualification](2026-11-09-runtime-qualification-results.md).                                                                                               | Verify the actual interactive Codex executable/configuration launched by SlopZooka, with its native tools and the preview MCP together. Earlier hosted CUA startup failures and app-handle auto-relaunch mean this is not an unconditional availability or exact-window guarantee. |
| Background Chrome input and frames                    | Owned extension/MCP worked with real terminal Codex and Pi; two streams were visible on Vision; background actions overlapped human typing without stealing that field. [Physical browser results](2026-11-09-surface-live-results.md), [owned extension](2026-11-09-owned-browser-extension-probe.md). | Separate capture from the controlling agent's lease; integrate the browser source into the regular Preview; test navigation, resize, detach/recovery and a clearly marked exact pixel/result check. One final reported browser counter did not match the oracle.                   |
| Codec choice                                          | Existing physical H.264 path plus 26 local benchmark cases. [Codec results](2026-11-08-mac-codec-benchmarks.md).                                                                                                                                                                                        | Measure real end-to-end text/motion/latency in the integrated build. Keep H.264 as the initial video path; the benchmark does not establish production capacity or headset performance.                                                                                            |
| External structured delivery into a live Codex worker | Same-runtime TUI/controller queue, steer, interruption, permission wait and uncertain-reply reconciliation. [Worker results](2026-11-10-worker-delivery-results.md).                                                                                                                                    | Needed later when Pi sends work into coding agents. **Not a dependency of a terminal agent calling our preview MCP.**                                                                                                                                                              |

There is no need for another broad multi-agent/headset feasibility slot before coding. There is also no claim that every fault, permission state or arbitrary application has passed. Start implementation with the established paths and qualify the narrower promise at each step.

## Sequence and release gates

### 1. Manual stream previews in the existing product

Extend the existing frontend catalog and preview resolver to describe web content or a bound stream. A stream is content within the existing Preview scene family, not a new window manager. Keep current web previews working. Use `CompanionClient` for authenticated requests and route revisions, `WindowGateway` for lifecycle/resolution and `WindowScene` for native presentation. Keep stable host/content IDs in layouts; resolve stream endpoints, trust and current target generations on use.

Start with one selected Mac window, then a Simulator window, using the already exercised ScreenCaptureKit/H.264 path. Source enumeration/capture belongs to the signed Mac component and its narrow companion bridge. Do not infer a source by title alone or silently switch to another window when the selected one disappears. A prepared device-frame provider remains a useful subsequent source/fallback; it is not necessary to reproduce the whole WDA experiment before shipping native window sharing.

Manual controls: select/show an available target, close, reconnect/reload when supported, and set a useful preview name. Use source aspect ratio, including a phone-shaped Simulator default. Capture is a viewer subscription owned by the provider; source app lifetime remains independent. Use one video path first. High-rate JPEG from the browser/device prototype is evidence, not the intended final universal transport.

**Gate:** one native fixture and one Simulator window work in the normal signed app, with fresh frames, expected aspect ratio and truthful loading/unavailable state. Explicit close stays closed; disconnect/background is not a close command; restoration works without the launcher; old resolutions cannot replace a newer source. A failed source does not silently restart an unrelated process or display a frozen image as live. Qualify permission detection/repair under the actual capture owner.

### 2. Small preview MCP in normal Codex terminals

Use a narrow local MCP adapter with launch-provided workspace/session context and a resolved paired-client destination. Add it to the real terminal harness without replacing or disabling its existing CUA/tools. UI and MCP call the same companion handlers. A per-terminal stdio bridge can carry the configured authority into those handlers; it does not own capture, terminal processes or layouts. Do not let model-supplied host/workspace IDs grant themselves access.

Provisional tool surface, to keep implementation small:

| Operation         | Behavior                                                                                                                                                                                                                                                       |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `previews.list`   | Return available exact target handles and existing scoped previews, names and readiness/errors. Enough information to distinguish similar windows and reuse an existing preview.                                                                               |
| `previews.open`   | Attach/show the selected target for the resolved client/workspace; optionally supply its initial name. Return stable preview ID and an honest accepted/presented/streaming outcome as available. Opening a preview does not itself mean launching another app. |
| `previews.close`  | End this preview's presentation/sharing subscription. Do not quit the source app, kill its terminal or end an unrelated viewer's subscription.                                                                                                                 |
| `previews.rename` | Change that preview's label through the same metadata owner as manual naming. Preserve explicit human edits against delayed automatic naming.                                                                                                                  |

Exact tool names and wire fields are implementation choices. Reload can initially use the existing UI or a retry/open operation with explicit semantics; do not add a general command language. Use bounded request correlation and replay-safe handling: transport retry must not create duplicate previews, and replaying an acknowledged old open after a user close must not reopen it. A new intentional open is a new request. If the headset is unavailable, return pending/unavailable rather than claiming the user can see it.

The useful first prompt is simply “Show this app beside my terminal,” followed by “Call it Settings” and “Close that preview.” No global model is required. App launch/build/navigation remain with the coding agent's existing shell/CUA tools; the preview MCP should not grow app-specific setup recipes.

**Gate:** a real SlopZooka-launched interactive Codex instance uses its normal native CUA to navigate the selected app, opens/names its preview through this MCP, and verifies a visibly marked change on Vision. Run a same-title decoy so matching the wrong app/window cannot pass. Exiting/disconnecting the MCP or finishing the turn leaves an explicitly open preview alive. Launch-time executable/version/configuration and native permissions must match the tested arrangement; earlier isolated `codex exec` and independent Pi tests do not substitute for this check.

### 3. Harden the preview/MCP slice in ordinary use

“Bulletproof” here means concrete bounded guarantees, not a promise about every app or operating-system state. Automate the protocol/lifecycle cases, then use one prepared headset slot for the changed UI/media path:

- Duplicate open, lost reply, delayed open after explicit close, rename racing a human edit, and repeated close.
- Viewer reconnect with the launcher absent; companion/capture-provider restart; source close/relaunch; permission loss and repair. Reject obsolete target generations and require a new binding when identity is uncertain.
- Two viewers with independent subscriptions; one closing does not black out the other. Closing the last viewer can pause capture without quitting the app. Native CUA completion/Stop must not implicitly release the viewing subscription.
- Resize/rotation, ordinary animation and text, bounded buffering under a stalled receiver, fresh keyframe/recovery and correct live/frozen/unavailable reporting. Measure action-to-visible response on the integrated source instead of using encoder FPS as a substitute.
- Locked/unlocked state is visible to tools/UI. Pause/report unavailable when the selected native path is gated; restore only its authorized target after unlock. The warm WDA result does not establish generic locked CUA or cold simulator launch. System sleep/lid closure and unattended cold start remain outside the initial guarantee.

Use the repository's shared-protocol fixtures and native injected transport/gateway checks. Follow the full verification commands in [CONTRIBUTING](../CONTRIBUTING.md#verify) for implementation. Physical verification remains necessary for actual frame quality and window close/restoration behavior. Do not repeat the earlier broad exploration or require the user to inspect every automated case.

### 4. Add background Chrome control and browser preview sources

Integrate the already-tested owned browser provider into the same preview/catalog path. The exact tab supplying the frames must be the tab receiving browser actions. Maintain distinct viewer subscriptions and input authority so terminal completion/Stop does not tear down a useful stream. A Chrome window captured as an ordinary Mac window can work earlier through native CUA; this step adds reliable tab-scoped background operation.

Use the owned extension as the currently demonstrated independent terminal integration. Codex's packaged desktop Chrome bridge has separate provisioning constraints; installing its extension did not establish arbitrary terminal-client access. Reuse that path only if it is legitimately available and passes the same test. Do not run two competing debugger owners against a target or silently substitute a fresh page at the same URL for an existing signed-in tab.

**Gate:** two terminals operate two distinguishable background tabs with a human typing elsewhere; both regular Preview windows show the correct fresh results. Include navigation, resize, debugger detach/provider replacement, stale actions and one-viewer close. Settle the old exact counter/pixel ambiguity using obvious target and frame markers. Qualify production video cadence separately from the earlier JPEG stream's qualitative visibility.

### 5. Add the ephemeral Pi coordinator

Only after previews and target controls are useful independently, add Pi's menu/context/voice entry points. Pi calls these same companion operations; it does not receive a second implementation of source launch, sharing, naming or window management. Integrate the qualified structured worker-delivery adapter here when Pi needs to queue/steer tasks in real coding sessions. Workspace preparation and automatic workspace naming then build on existing Mac owners.

The preview MCP can remain a small caller adapter if coding agents still benefit from direct show/close/name requests. It can be removed later if product experience demonstrates that Pi should be the sole caller. **Do not move the underlying controls into Pi or make source/view lifetime depend on it.** Removing a thin MCP wrapper is cheap; removing a second lifecycle implementation would not be. Direct Pi CUA versus delegation remains an explicit later decision, informed by this simpler rollout.

P2 thread browsing/handoff and semantic focus overlays retain their separate scope. Neither a new native conversation UI, direct human input over video nor a Chromium embedder is a prerequisite for this rollout.

## Native CUA and preview identity need an honest boundary

The initial paths are deliberately separate:

```text
Coding agent → its existing native CUA → actual Mac app/window
Coding agent → preview MCP → existing companion owners → WindowGateway → Vision Preview
```

The MCP supplies authoritative target identity/context; capture enforces its selected source. It does not automatically intercept every action sent through Codex's opaque native CUA. The inspected app handle can relaunch/follow an app, so neither an app name nor a successful handle lookup proves immutable window identity. Test that control and capture agree, invalidate changed bindings, and limit supported control claims when the provider cannot distinguish windows reliably.

Similarly, **Close preview/Stop sharing is not Stop computer use.** The coding agent retains its native interruption path. Do not advertise a preview-scoped input revocation guarantee while actions bypass the companion's input admission. If a dedicated per-preview Stop/control guarantee is required, route those actions through an enforceable adapter and qualify in-flight cancellation; that is additional work, not something supplied by a stream.

Using native CUA already available in the user's Codex harness avoids building another computer-use engine in this first slice. It does not justify assuming every plain CLI installation has the same plugin provisioning. Keep permission ownership explicit: the signed capture component needs its own capture access, while native control follows the actual Codex helper's requirements. No vendor runtime redistribution is part of the preview MCP.

## What remains before starting

No further broad feasibility experiment is required. Finalize the small stream discriminator, exact target reference, open/close/name semantics and existing-owner placement as part of the first implementation review. The defaults above make that concrete. The first integration gate is the real interactive Codex + native CUA + preview MCP + matching rendered source; it can be developed alongside manual preview support.

This note changes plans only. It records no new live test, product implementation or permission change. The next action is the manual stream-preview slice, followed by the four-operation MCP and its focused device check.
