# Optional immersive workspace and wrist controls

## Purpose and scope

Add a runtime, opt-in mixed immersive space to the existing windowed app. The room
and SlopZooka windows remain visible; visionOS hides other applications until the
space closes. This is a small presentation addition, not a second terminal app.

The launcher gear opens Settings. Settings contains the immersive toggle, a wrist
selector while enabled, Mac connection controls, and troubleshooting. The launcher
retains visible connection status and first-run/error recovery. Project creation,
tool selection, and workspace maintenance remain with Projects. Terminal-specific
controls remain in each terminal. Reload All Window Content is deliberately named
for its existing gateway-wide scope.

The wrist palette opens the launcher, opens up to three recent terminals, and exits
immersion. It uses ordinary SwiftUI buttons with standard targeting and hover
feedback. There is no custom palm gesture: visionOS already uses palm gestures for
Home and Control Center. Switching modes does not close, recreate, or end terminals.
Exiting explicitly opens the launcher so there is a normal scene to return to even
if the wrist was the last scene.

## Ownership and invariants

- `WindowGateway` remains the only route for terminal/preview lifecycle, session
  actions, content resolution, and restoration. The wrist renders its existing
  session collection and calls `open(id:)` / `openLauncher()`.
- `WindowScene.swift` owns native window and immersive scene actions. Its shared
  `SceneActions` adapter registers either scene type as a presenter. The immersive
  scene can open windows without a launcher window being alive. Only native window
  scenes install the UIKit session-identity bridge.
- The gateway owns one `ImmersiveWorkspaceState`. Its phase is transient:
  inactive → opening → active → closing → inactive. Native transitions are
  serialized. A request token prevents late open/dismiss replies from overwriting
  state after a system dismissal or a newer request.
- Scene disappearance updates immersive state, but is never a terminal close
  command. Companion window records and PTY lifetime remain independent.
- Only left/right wrist preference is stored in UserDefaults. Immersion starts off
  on a new process launch. No wrist pose, permission state, or immersive scene is
  written into the companion layout or local window outbox.
- `MacConnectionView` is the same form in onboarding and Settings. Discovery,
  connection, and refresh ownership stay in the existing gateway; neither new UI
  starts a duplicate service loop.

## Rendering and platform boundaries

`WristWorkspaceView` uses RealityKit wrist anchors and one SwiftUI attachment. Hand
selection reparents that same attachment. RealityKit maintains the anchor itself;
we do not read hand transforms, run an ARKit provider, request raw hand data, or
implement per-frame tracking/smoothing. Standard SwiftUI attachment controls handle
interaction. This keeps the feature independent of raw hand-tracking authorization.

Apple defines wrist +Y as pointing out of the back of the hand and +Z toward the
thumb. The palette is offset 4.5 cm above the wrist and 12 cm toward the forearm; its
front faces outward and its top points toward the fingers on either hand. The
320-point attachment is scaled to 0.6 (about 19 cm wide). These are starting values
for headset validation, not a claim that ergonomics have already been proven.

The simulator renders the same controls in front of the viewer using a one-time
head anchor, with an explicit simulator note. It cannot establish wrist tracking,
physical orientation, readability, or selection comfort. The old noninteractive
Palm Spike window has been removed.

The normal Launcher, Terminal, and Preview scene IDs and values are preserved.
Physical placement of ordinary windows still belongs to visionOS. Adding an
immersive scene does not grant arbitrary positioning of those windows.

## Verification

Required automated checks: `pnpm test:vision-state`, `pnpm typecheck`, `pnpm test`,
`pnpm format:check`, `pnpm build:harness`, and the README visionOS simulator build.
The state suite covers entry, cancellation, retry after failure, repeated toggles,
system dismissal, late replies, and wrist-only preference persistence. Existing
gateway/persistence regression checks continue covering window intent and recovery.

Before calling the interaction device-validated, check on physical Vision Pro:

1. Enter from Settings with multiple terminals and a preview; existing content and
   sessions stay intact. Other applications return on exit.
2. Try both wrists; verify outward orientation, text size, hover, and repeated
   selection while resting the hand, including clearance from system hand overlays.
   Move the hand out of tracking and back.
3. Close the launcher and other windows, reopen one from the wrist, then exit with
   only the wrist remaining. Confirm the launcher remains available.
4. Cancel entry, dismiss via the system, and toggle repeatedly; Settings must match
   the actual space without duplicate spaces or stuck transition controls.
5. Disconnect/reconnect the Mac, sleep/wake, and relaunch the app. Verify pairing,
   recovery, session identity, and that the app starts in normal mode.

## Deliberate extension boundary

A later “Place here” option could mount this same palette in the room. A status
display can reuse available connection/session/frontend data; agent task progress
would require separate, real telemetry. Wrist dictation requires explicit target
selection and shared microphone ownership. A custom terminal cockpit would be a
separate rendering/placement project. None of these are part of this change.

Do not add a second window registry, persistence layer, scene router, or generic
mode framework to extend the wrist UI. Keep one owner per responsibility and use
the existing gateway for all terminal and preview actions.

## References

- [Windows and immersive spaces](https://developer.apple.com/documentation/visionos/presenting-windows-and-spaces)
- [Wrist anchor coordinates](https://developer.apple.com/documentation/realitykit/anchoringcomponent/target-swift.enum/handlocation/wrist)
- [Privacy-preserving anchoring](https://developer.apple.com/documentation/realitykit/spatialtrackingsession)
- [System gestures](https://developer.apple.com/design/human-interface-guidelines/gestures)

## Implementation validation record

- Swift launcher, gateway/persistence, and immersive lifecycle checks: passed.
- TypeScript type checking and formatting: passed.
- Companion suite: 31/31 passed from an identical source copy under `/tmp`.
  In the managed worktree, the existing absolute-path `sendFile` route returns 404
  because Express rejects the `.codex` ancestor as a dotfile path. A minimal
  reproduction returned 404 for the absolute path and 200 with a public-root path.
  No companion server change is included in the wrist feature.
- Harness build: passed; committed public assets remain unchanged.
- visionOS simulator and device-SDK compilation: passed with Xcode 26.3.
- Interactive simulator inspection was blocked by the locked Mac. A simulator
  build/install/launch is not a claim that the controls were visually verified.
- Physical wrist interaction is pending the device checklist above.

The feature is developed against the separately authored window-gateway foundation.
The local prerequisite snapshot is not part of the wrist feature's intended PR;
rebase the wrist commit onto that foundation once it lands independently.
