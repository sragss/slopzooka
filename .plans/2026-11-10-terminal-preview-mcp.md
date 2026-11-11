# Terminal preview MCP: first implementation slice

Starts after transport #54 and native previews #56. Keep the MCP a stateless
adapter to the existing Mac APIs and WindowGateway; Codex's native computer-use
runtime remains responsible for interacting with the source application.

## Tool contract

| Tool | Input | Result |
| --- | --- | --- |
| `preview_list` | none | Current native sources, capture availability and this target headset's desired native previews. Source IDs are opaque and must come from this call. |
| `preview_open` | `source_id`, optional `name` | Validate the current source, add/reuse its stable preview record in the existing client layout, return the preview ID and acknowledged desired state. |
| `preview_rename` | `preview_id`, `name` | Change presentation metadata on that same record without creating a scene or changing source identity. |
| `preview_close` | `preview_id` | Remove only that native preview's desired-open intent; WindowGateway dismisses its scene and releases the viewer. The source app and PTYs survive. |

No shell, click, keyboard, app-launch, arbitrary URL, port proxy or workspace tool
in this MCP. Codex can use its existing terminal/CUA capabilities, then register
an observed source. Starting with native sources avoids claiming web availability
from the Mac-local route when the destination headset is using Direct.

A successful mutation reports **desired state acknowledged**, not “visible to the
user.” Neither an API response nor a sender ACK proves physical presentation.
Tool responses never contain bearer tokens, ephemeral media URLs or capture tickets.

## Binding and authorization

Bind one adapter instance to an explicit companion identity and headset client ID.
Do not guess the headset from the last log entry, the first layout or whichever
launcher is visible. That was acceptable only in the disposable operator rig.

The initial development setup can use an explicit private configuration file for
an already paired local companion and target headset. Keep credential material out
of model arguments and stdout. Validate host identity before mutations and use the
existing bearer authentication. This file is not a new layout/session store.

Production integration should pass the initiating headset/client context when the
Mac launches a Codex terminal, rather than asking the agent to select it. Preserve
retained-session compatibility: old terminals cannot be assumed to acquire new
environment/configuration after a companion upgrade. Decide the concrete credential
provisioning and packaged executable path before enabling automatic registration;
do not silently edit the user's global Codex configuration during development.

## Existing boundaries to extend

1. `WindowLayoutStore` remains the only durable owner. Mutations fetch the latest
   revision, apply a single intent and retry a bounded number of CAS conflicts.
   Never replace the full layout with an old agent snapshot. Two agents opening
   distinct sources and a user closing another window must compose correctly.
2. `WindowGateway` currently restores records that are present, but does not
   dismiss a live scene simply because a remote layout removed its record.
   Add reconciliation after a successful authoritative fetch, respecting pending
   local intent. Failed fetches, unknown initial state and disconnects must never
   count as remote closes. Native dismissal still goes through WindowScene.
3. Add optional display-name metadata compatibly to the TS and Swift window
   schema and fixture. A label must not enter stable scene/content equality:
   archived predecessor scenes can carry an older label. Keep pending-write
   equality sensitive to metadata changes, while discard matching uses stable
   host/window/source identity. Update live headers through gateway state without
   reconnecting media just to rename it.
4. A preview close must also cancel an in-flight resolve and ignore its late
   result. A subsequent explicit open may create a new scene; unrelated scene
   observations must not resurrect the closed preview.

## Implementation sequence and verification

- First implement authoritative remote-close and label reconciliation at the
  existing gateway/schema boundary, with real persistence tests for late replies,
  close versus disconnect, renamed archived replacements and launcher-free use.
- Then add a small HTTP adapter plus SDK-based stdio server. Verify initialization,
  tool listing, schemas and tools/call using a real MCP client over child stdio,
  an isolated authenticated companion fixture and the real layout store.
- Exercise two concurrent adapters, CAS conflicts, wrong target/host, missing or
  restarted source, permission/lock state, source close and adapter restart. Assert
  that PTY creation/termination APIs are never invoked and other windows survive.
- Package the same executable for Codex configuration; test it with the installed
  CLI without changing global user settings or running a model against live windows.
- Finish with a short device gate: a Codex terminal opens and names a simulator
  preview, computer use changes the fixture, then MCP close really dismisses it
  with the launcher closed. Two independent terminals must not cross-target previews.

Keep this as a separate PR. The merge authorization for #54/#56 does not make the
new MCP device gate unnecessary.

## References checked

- [Codex MCP commands](https://learn.chatgpt.com/docs/developer-commands#codex-mcp):
  stdio launcher configuration; the installed `codex mcp add --help` also confirms
  command arguments, environment options and per-command configuration overrides.
- [Official MCP TypeScript SDK server](https://ts.sdk.modelcontextprotocol.io/v2/get-started/first-server)
  and [stdio serving](https://ts.sdk.modelcontextprotocol.io/v2/serving/stdio): use
  the SDK server factory/stdio transport, rather than implementing JSON-RPC here.
  Registry inspection on 2026-11-10 reports `@modelcontextprotocol/server` 2.4.0;
  pin and validate the selected SDK during implementation.
