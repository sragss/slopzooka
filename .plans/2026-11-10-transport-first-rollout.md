# Transport first; preview support follows the active connection

November 10, 2026. **Updated user direction:** centralize transport before the new preview/MCP work. Retain direct web previews, but permit them to be temporarily unavailable where their networking is not qualified. UI and agents must receive the same availability information. This supersedes the earlier recommendation to defer the shared transport seam until after preview implementation; full travel-mode qualification and universal web forwarding can still come later.

**First implementation PR:** shared transport, manual connection-method selection and consistent presentation availability. Suggested title: **“Centralize companion transport and add manual LAN/direct selection.”** Keep the existing draft research PR as the evidence/design record; the production PR should contain the focused implementation, regression coverage and usage/architecture updates, without importing the experimental harnesses. New preview types, the terminal preview MCP and Pi follow in separate PRs.

## Initial Settings UX and fallback policy

Add **Connection method** to the existing **Settings → Connected Mac** flow, with exactly two choices. Do not expose Auto or a separate fallback toggle in this PR.

| Choice            | Meaning                                               | Initial behavior                                                                                                                                                                               |
| ----------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Local Network** | Reach this Mac through the local network              | Default; preserves the current product path. A manual IP/hostname is available in this mode.                                                                                                   |
| **Direct to Mac** | Use a verified nearby peer link for SlopZooka traffic | Explicit opt-in; initially labeled Experimental while the broader travel/wake UX is being qualified. Explain inline that Wi-Fi radios must stay enabled and some web previews are unavailable. |

The choice is per paired Mac **on this headset**, keyed by authenticated host ID and owned by the existing connection preferences/client. It is not a global Mac preference, does not change another headset's route, and does not belong in window records. Before pairing, the chooser can set the current connection attempt's method; associate the saved preference with the verified host only after pairing. Do not require a prior LAN session just to select Direct; cold no-AP enrollment remains a release qualification before promising that use case.

Show selected method and actual state separately: for example, **Direct to Mac · Connecting**, **Connected via Direct**, or **Direct unavailable**. “Selected Direct” is not proof that a direct connection exists. Keep these controls reachable while disconnected and from an existing window's Settings entry, including when the launcher was closed. Recovery must not require the connection being repaired.

**Strict manual policy:**

- Automatically retry/reconnect within the selected method using bounded attempts and backoff. Stop peer browsing when a candidate is selected; avoid continuous scanning between attempts.
- Do not automatically switch from Direct to LAN, from LAN to Direct, or to a different Mac. On failure, show the actual reason and **Retry** plus an explicit **Use Local Network** or **Use Direct to Mac** action where supported. The alternate action changes the preference; it does not promise that the alternate is reachable.
- Direct means an established peer route, not `includePeerToPeer=true`. The adapter must constrain/verify the path before admitting product traffic, and enforce that choice for new control, terminal and media connections too. An unresolved or unexpected path is a failed attempt, not “Connected via Direct.” No hardcoded interface names. Keep discovery/identity verification distinct from admitting application channels.
- A manual LAN address must not bypass a Direct selection. The user can choose Local Network to use it. Browsers, source providers and tool adapters cannot opportunistically send traffic over the other route to make an individual preview succeed.
- MCP/agent context reports selected method, active state and supported presentations. In this first PR, agents can explain the limitation or point to Settings; they do not mutate the method behind the user's back. Direct web previews remain disabled on an unqualified Direct route even if a usable LAN happens to exist.
- Preserve a failed selection across app restart. Do not silently reset it to Local Network. Unsupported companion/client versions show a specific update/unsupported reason and the explicit recovery choice; the Experimental label does not permit a nonfunctional or mislabeled adapter.

## Switching method: a small, explicit transition

Apply a selection immediately, without another confirmation dialog. Show an inline note that content reconnects and affected web previews may reload/lose in-page state. For PR 1, use a simple **disconnect then connect** transition rather than adding simultaneous active routes, automatic rollback or live socket migration:

1. Save the requested method, advance the route/selection revision, and retire the prior channels plus in-flight resolutions. Stop admitting input through the old terminal document. Clear old active-route support; never display the previous method as the newly selected connection.
2. Keep terminal processes, stable window records, names and scenes. Show connecting/unavailable presentation as appropriate; retain normal local close/pending persistence behavior. Do not buffer uncertain keyboard input or replay an interrupted non-idempotent request.
3. Discover/connect/authenticate using the selected method. Activate that route and publish its support only after it is accepted; reattach existing terminals and re-resolve still-open previews. Unsupported web windows become placeholders, not silently substituted Mac browser streams.
4. If it fails, stay selected-but-disconnected with Retry and the explicit alternate-method action. If the user changes their choice again, cancel the old attempt; late success from it cannot steal selection, revive a closed preview or grant credentials to another origin. Choosing the previous method reconnects normally, not through a hidden retained channel.

This deliberately accepts a brief reconnection pause. Same-method reconnect remains automatic; cross-method fallback remains manual. A later Auto mode would add measured route health, bounded probing, hysteresis and visible transitions behind the same connection owner, with explicit user opt-in. Do not build those policies now or migrate existing manual choices to Auto without consent.

## Scope and ownership

Centralize connection establishment, authenticated Mac identity, route selection/revision, credential binding, cancellation and support information. Keep control requests, terminal streams and media independently bounded. Each carries its existing protocol; sharing a route does not require one socket or one serialization format. Route changes do not own PTYs, desired window layouts, source apps or scene placement.

| Responsibility                                                | Owner/direction                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Discover/pair/select the Mac; resolve current route and trust | Extend the existing `CompanionClient`, with a small native transport dependency. Do not add another independently observable host/connection registry.                                                                                                                                            |
| HTTP/control, terminal channel, media channel                 | Purpose-specific operations on the selected authenticated route. Concrete adapters establish sockets/requests; feature views and MCPs do not choose addresses or interface names. Media bytes stay native and bypass JavaScript/JSON dispatch.                                                    |
| Mac peer-aware ingress                                        | A narrow native adapter forwards admitted control/terminal traffic to existing companion/session handlers. Existing process/domain owners remain authoritative; no duplicate Swift API implementation or generic arbitrary-port tunnel. Coordinate advertisement and lifetime with the companion. |
| Terminal rendering                                            | Keep xterm and the shared terminal protocol/state machine. Add a transport adapter for the controlled terminal document; preserve the ordinary browser WebSocket adapter for the desktop dashboard.                                                                                               |
| Presentation availability                                     | One shared, versioned result per paired client/route and target, derived from actual endpoint support, client renderer support, source readiness and policy. Existing catalog/resolve/open handlers expose and enforce it.                                                                        |
| Window lifecycle                                              | `WindowGateway` consumes the resolved presentation/availability. `WindowScene` remains the native scene adapter. Persistence continues to store stable host/content references only.                                                                                                              |

The transport boundary should expose a native request operation and independently scoped terminal/media connections, rather than a generic message bus. A handle identifies the paired host and current route revision; its implementation owns transient endpoints/trust. Concrete names/types follow implementation. A caller cannot obtain authority by submitting a host ID, route name or capability revision. New routes must prove the paired Mac's identity before receiving its credentials.

## The important terminal distinction

The terminal is a WebView too, and is required on every route we advertise as usable. It cannot be treated as an optional unsupported web preview. Today's `CompanionClient.Exchange` only intercepts native HTTP requests; `terminal-connection.ts` independently constructs a browser `WebSocket`, and `CompanionWebView` loads the terminal document by URL. Moving only the request exchange would leave the core transport decentralized.

Preferred implementation direction: keep the first-party terminal renderer and its attachment/cursor/ack/input behavior, extract its socket dependency, and supply a small native message bridge in Vision. Its document/assets must also load through the owned route adapter or be bundled with an explicit version check. Do not accidentally leave startup dependent on an independently reachable LAN URL. Select the less complex asset-loading implementation in the first slice; no arbitrary website proxy is needed just to serve our own terminal assets.

Keep one terminal protocol/retry state machine. The connection owner chooses the route; the terminal attachment logic handles attach/replay against it. Avoid nested native and JavaScript retry loops creating duplicate attachments. Bound traffic across the JS/native bridge, admit messages only from the intended first-party document/session, retire callbacks and input from replaced documents/routes, and preserve keyboard/focus/resize behavior. Do not automatically replay uncertain keyboard input after a disconnect. Native credentials never become a general-purpose API exposed to preview pages.

## Web previews remain a supported presentation kind

Keep the existing `WKWebView` presentation and working LAN gateways. Its support becomes a property of the active route and target, rather than an assumption inferred from an open port. Initially:

| Presentation                 | Qualified LAN route                             | Initial peer route                                                                            |
| ---------------------------- | ----------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Terminal                     | Required; preserve current behavior             | Required before enabling that route for normal work                                           |
| Native Mac/window stream     | Enable after the production stream slice passes | Enable only when the same source/receiver is qualified on this route                          |
| Direct web preview in Vision | Retain existing working behavior                | May be disabled until URL loading, authentication, redirects and WebSockets/HMR are qualified |

“Disabled on this route” is an implementation/support limitation, not a claim that WebKit or the network can never support it. A public Internet URL and a Mac-local dev server may eventually have different support, but do not add speculative exceptions initially. A shared route for SlopZooka does not automatically provide Internet access to arbitrary WebView subresources.

**Naming detail from current code:** `FrontendSummary.transport == "direct"` currently means direct URL presentation rather than use of a Mac preview gateway. It does **not** mean peer-to-peer Wi-Fi. Keep presentation mode and connection route as separate concepts; do not overload that existing field and silently reinterpret old payloads.

## One availability result for UI, MCP and execution

Use actual negotiated/runtime facts, not an agent's judgment about networking. A minimal result includes whether a presentation can be opened, a stable reason code, a user-readable explanation, and available alternatives. Bind it to the target client and route/support revision. Keep source status (starting/stopped), missing permissions, offline state and unsupported presentation distinct.

The companion's shared presentation resolver produces the canonical result from the authenticated destination's current facts. Swift renders that result and applies immediate local revision/readiness checks; MCP returns it. Do not independently reproduce a route-to-preview feature matrix in TypeScript, Swift and tool prompts. Capabilities describe support, not authorization; permission/admission checks still apply when support is true.

Keep wire changes additive where possible and define the existing-version LAN behavior explicitly in a compatibility profile/fixture. Missing new capability fields must not invent peer or stream support, or accidentally disable already-supported legacy LAN terminals/web previews. Update TypeScript/Swift decoding and shared fixtures together; a genuinely incompatible peer adapter can require an update instead of guessing.

For example, a healthy admin frontend on an unqualified peer route could report:

```json
{
  "presentation": "web",
  "available": false,
  "reasonCode": "presentation_unsupported_on_route",
  "message": "Web previews are not supported on this connection yet.",
  "alternatives": []
}
```

Populate alternatives only when supported and ready. A Mac browser stream is useful later, but must not appear as available merely because it is planned or a browser could theoretically be launched. Agent launch/navigation remains separate from choosing the presentation. Native Mac computer use may still work even when a target cannot currently be shown on Vision.

- **Catalog/UI:** keep the frontend discoverable, disable its Open action and show the reason. Preserve bookmark management, renaming and closing. Do not label an unsupported presentation as a stopped app or an empty catalog. Show a supported alternate action when one exists.
- **Tools:** list/discover responses return the same availability and reasons. Open rejects an unsupported request with a structured result before allocating a gateway, stream or window. Tool guidance says to choose an available representation or explain the limitation; rebuilding/relaunching the same web server will not fix route support.
- **Execution:** shared companion handlers validate the current destination's negotiated support; `WindowGateway` validates again before resolving/presenting. A stale list response or a model ignoring guidance cannot bypass the restriction. The Mac maintains the current authenticated client's advertised renderer/route facts within the existing connection/presentation state—not a second durable capability database. Missing/stale client facts yield unknown/unavailable, never presumed support.
- **Changes:** publish support with the route revision and source/policy updates; reject late results and pending opens for an obsolete revision. Per-client scope matters: a LAN headset and a peer headset connected to the same Mac may legitimately have different available presentations. Unknown presentation kinds fail closed while existing protocol compatibility remains explicit.

Do not silently change a user's connection policy to make an Open succeed. PR 1 uses the strict manual method above. Any later automatic policy still belongs to the connection owner with visible state/support updates, not a per-preview URL fallback. “Use a Mac browser stream” is a different presentation and can have different login/session state; do not silently substitute it for the user's existing WebView.

## Existing windows when support changes

On LAN → peer when web presentation is unsupported, keep the window's stable record, name and spatial scene, retire the old WebView/network activity and show an unavailable placeholder with the reason. Merely stopping a page load is insufficient if its old scripts/sockets continue using the retired route. Do not close/delete the window, show a frozen page as live, launch a second browser or leave an undisclosed LAN connection running behind a “direct” status.

On a later supported route, re-resolve the still-open window through `WindowGateway`. This may reload the page; do not promise preservation of unsaved in-page state. An explicit user close stays closed. Local close/pending persistence intent continues to work while disconnected; route recovery never creates another terminal process. The launcher must not be required for any of this.

## Implementation order and exit criteria

1. **Centralize with LAN parity.** Move native control and the owned terminal document/socket behind the selected-host transport boundary. Preserve the browser dashboard's normal WebSocket adapter and existing direct web previews through an explicit legacy LAN presentation adapter. Their network behavior is an acknowledged adapter boundary, not scattered route selection in views. Verify ordinary work, keyboard handling, reconnect and authentication before adding a second transport.
2. **Exercise the second adapter.** Use the qualified native peer listener to run a real terminal and control request through the same boundary. Keep the workload and protocols unchanged. This validates the abstraction with an actual different route, rather than mocks alone. Peer production enablement still requires proper identity/pairing and lifecycle qualification; fixture pins are test provisioning only. No-AP travel claims retain the separate cold-discovery/wake check.
3. **Land manual Settings selection, shared availability and transition behavior.** Test an unsupported web presentation through manual UI, a direct API/tool call, and system restoration. Test stale requests, two clients with different routes, peer → LAN recovery, and explicit close during recovery. Keep this within existing catalog/client/gateway owners; no separate policy service or model-mediated permission layer.
4. **Then resume manual stream previews → small preview MCP → hardening → background Chrome → Pi.** New media uses the established native connection boundary. Do not wait for universal peer WebKit forwarding; advertise only implemented combinations. Until a stream provider exists, an unavailable web preview can truthfully have no alternate presentation.

The first implementation PR is complete when all core native control and terminal communication flows through the selected-host boundary, LAN behavior is preserved, the peer adapter exercises the same contract, manual selection/recovery is usable, and route-specific unsupported previews fail consistently without changing window/process lifetime. Neither a general VPN, custom multiplexing protocol, full browser proxy, new orchestrator nor a replacement session service belongs in it.

Verification uses the existing shared protocol fixtures, injected native client/gateway tests and the repository's full checks in [CONTRIBUTING](../CONTRIBUTING.md#verify). Add meaningful regressions for stale route replies, old-document input, reconnect without the launcher, per-client availability, close while unsupported, bounded terminal backpressure and avoiding duplicate attachments/processes. Real-device verification covers terminal input on the peer adapter and native scene behavior. The earlier raw-byte link probe does not establish these application guarantees.

For the manual policy, explicitly cover: default/migrated LAN preference; successful switches both ways; Direct unavailable while LAN is healthy (no fallback); loss of an established Direct connection (same-method retry only); rapid toggles with late success; restart after a failed choice; rejected authentication; current method unsupported after a version change; stale agent Open during a switch; independent headset/Mac preferences; and Settings recovery without the launcher. Verify path selection for each channel rather than only the first health/control connection. No-new-terminal-process and explicit-close assertions apply throughout.
