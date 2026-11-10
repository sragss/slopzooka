# Transport first; preview support follows the active connection

November 10, 2026. **Updated user direction:** centralize transport before the new preview/MCP work. Retain direct web previews, but permit them to be temporarily unavailable where their networking is not qualified. UI and agents must receive the same availability information. This supersedes the earlier recommendation to defer the shared transport seam until after preview implementation; full travel-mode qualification and universal web forwarding can still come later.

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

Do not silently change a user's connection policy to make an Open succeed. An automatic connection policy may select a different authenticated route; that is a connection-owner decision with visible state/support updates, not a per-preview URL fallback. “Use a Mac browser stream” is a different presentation and can have different login/session state; do not silently substitute it for the user's existing WebView.

## Existing windows when support changes

On LAN → peer when web presentation is unsupported, keep the window's stable record, name and spatial scene, retire the old WebView/network activity and show an unavailable placeholder with the reason. Merely stopping a page load is insufficient if its old scripts/sockets continue using the retired route. Do not close/delete the window, show a frozen page as live, launch a second browser or leave an undisclosed LAN connection running behind a “direct” status.

On a later supported route, re-resolve the still-open window through `WindowGateway`. This may reload the page; do not promise preservation of unsaved in-page state. An explicit user close stays closed. Local close/pending persistence intent continues to work while disconnected; route recovery never creates another terminal process. The launcher must not be required for any of this.

## Implementation order and exit criteria

1. **Centralize with LAN parity.** Move native control and the owned terminal document/socket behind the selected-host transport boundary. Preserve the browser dashboard's normal WebSocket adapter and existing direct web previews through an explicit legacy LAN presentation adapter. Their network behavior is an acknowledged adapter boundary, not scattered route selection in views. Verify ordinary work, keyboard handling, reconnect and authentication before adding a second transport.
2. **Exercise the second adapter.** Use the qualified native peer listener to run a real terminal and control request through the same boundary. Keep the workload and protocols unchanged. This validates the abstraction with an actual different route, rather than mocks alone. Peer production enablement still requires proper identity/pairing and lifecycle qualification; fixture pins are test provisioning only. No-AP travel claims retain the separate cold-discovery/wake check.
3. **Land shared availability and transition behavior.** Test an unsupported web presentation through manual UI, a direct API/tool call, and system restoration. Test stale requests, two clients with different routes, peer → LAN recovery, and explicit close during recovery. Keep this within existing catalog/client/gateway owners; no separate policy service or model-mediated permission layer.
4. **Then resume manual stream previews → small preview MCP → hardening → background Chrome → Pi.** New media uses the established native connection boundary. Do not wait for universal peer WebKit forwarding; advertise only implemented combinations. Until a stream provider exists, an unavailable web preview can truthfully have no alternate presentation.

The foundation is complete when all core native control and terminal communication flows through the selected-host boundary, LAN behavior is preserved, the peer adapter exercises the same contract, and route-specific unsupported previews fail consistently without changing window/process lifetime. This is the first product implementation slice; neither a general VPN, custom multiplexing protocol, full browser proxy, new orchestrator nor a replacement session service belongs in it.

Verification uses the existing shared protocol fixtures, injected native client/gateway tests and the repository's full checks in [CONTRIBUTING](../CONTRIBUTING.md#verify). Add meaningful regressions for stale route replies, old-document input, reconnect without the launcher, per-client availability, close while unsupported, bounded terminal backpressure and avoiding duplicate attachments/processes. Real-device verification covers terminal input on the peer adapter and native scene behavior. The earlier raw-byte link probe does not establish these application guarantees.
