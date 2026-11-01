# Window architecture

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

Verify changes with `pnpm test:vision-state`, `pnpm typecheck`, `pnpm test`,
`pnpm format:check`, `pnpm build:harness`, and a visionOS simulator build as documented
in README. Window persistence tests must cover late replies, explicit close versus
disconnect, recovery without the launcher, and avoiding duplicate process creation.
Real-device validation is needed for placement across Xcode installs and system
close/room-lock behavior; simulator compilation does not establish those guarantees.
