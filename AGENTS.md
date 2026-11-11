# Repository guidance

SlopZooka is a macOS companion and visionOS client for spatial coding. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for development and verification, and
[docs/architecture.md](docs/architecture.md) for the source map and ownership.
Historical plans in `docs/archive` are context, not current requirements.

## Working conventions

- Keep process and workspace ownership on the Mac. Headset views request intent
  and render state; terminal processes belong to the session service.
- Edit browser sources in `apps/mac-companion/src`, then regenerate the checked-in
  assets with `pnpm build:harness`. Do not hand-edit bundled JavaScript.
- Keep shared protocol changes compatible with the Swift client and update the
  relevant regression coverage and fixtures.
- Update the relevant usage guide for user-facing changes.
- Keep the README concise and user-facing: the product pitch, a short setup path,
  and links. Use plain, fun language with a touch of sarcasm. Put detailed usage
  in the relevant guide, development commands in CONTRIBUTING, and ownership rules here.

## Logging

Use the existing scoped logger: Node components receive
`diagnostics.logger("component")`, browser components use `browserLog("component")`,
and native components use `AppLog("component")`. Bind stable IDs with `child` and
record named events with structured metadata. Components do not own log storage;
keep writer setup at process bootstrap and preserve the bounded diagnostics pipeline.
Never log raw input, transcripts, credentials, request bodies, or environment dumps.
Summarize high-volume traffic. See [Logging](CONTRIBUTING.md#logging) for error
handling, correlation, and incident-capture privacy rules.

## Window architecture

Route all terminal/preview window lifecycle decisions through `WindowGateway.swift`.
It is the sole gateway for opening, closing, content reload, session launch/end,
payload resolution, and restoration. Views request intent and render its state;
they must not register payloads, construct gateway URLs, or maintain another list
of windows. Keep native `openWindow` / `dismissWindow` calls in `WindowScene.swift`.

Persistence has one owner on each side:

- `apps/mac-companion/src/window-layout.ts` owns durable desired window layouts,
  partitioned by the existing client ID. Saves are atomic and revision checked.
- `WindowPersistence.swift` synchronizes that layout and persists only pending
  local changes until acknowledged. Rebase pending intent after conflicts; never
  replace a fetched layout with an old local snapshot.
- `WindowScene.swift` adapts native scene presence and permanent discard events.
  Disconnect, background, focus loss, and `onDisappear` are observations, not close
  commands. System-restored windows resolve through the same gateway as new ones.

Persist stable host/content identifiers. Resolve URLs, gateway tokens, and trust
material when needed; never put them in window records. Physical placement belongs
to visionOS. Per-scene view preferences can use `SceneStorage`. PTY lifetime remains
independent of windows and belongs to `SessionManager` on the Mac.

For new window kinds or lifecycle behavior, extend this boundary and its schema
rather than adding a parallel persistence or routing mechanism. Keep the TypeScript
and Swift window schemas compatible. Preserve scene IDs and values when possible.

## Verification

Verify changes with `pnpm lint`, `pnpm test:vision-state`, `pnpm typecheck`,
`pnpm test`, `pnpm test:terminal-keyboard`, `pnpm format:check`, `pnpm build:harness`, and a
visionOS simulator build as documented in [CONTRIBUTING.md](CONTRIBUTING.md#verify).
Window persistence tests must cover late replies, explicit close versus disconnect,
recovery without the launcher, and avoiding duplicate process creation.
Real-device validation is needed for placement across Xcode installs and system
close/room-lock behavior; simulator compilation does not establish those guarantees.
