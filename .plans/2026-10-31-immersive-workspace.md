# Optional immersive workspace and wrist controls

## Product scope

The launcher gear opens Settings: an immediate **Immersive workspace** toggle,
left/right wrist preference, the existing Mac connection form, and troubleshooting.
Connection status and first-run recovery stay visible in the launcher. Project and
terminal actions stay with their respective content. Reload All Window Content
retains its existing gateway-wide scope.

Mixed immersion keeps the room and SlopZooka windows visible while visionOS hides
other apps. The wrist palette opens the launcher, opens three recent terminals,
and exits. Exiting opens the launcher first so a normal scene remains available.
Switching modes never closes terminal windows or ends their sessions. Immersion
starts off; only the wrist preference persists.

## Ownership

- `WindowGateway` remains the single owner of terminal/preview intent, identity,
  content resolution, and recovery. The wrist reads its existing session list and
  calls its existing actions. No new companion schema or window registry is needed.
- `WindowScene.swift` contains all native window and immersive actions. The shared
  `SceneActions` adapter lets the wrist present windows even with the launcher
  closed. Only ordinary windows install the UIKit session-identity bridge.
- `ImmersiveWorkspaceState` separates **observed visibility** from **an in-flight
  native call**. Entry/exit stays locked until the native call returns, including
  after system dismissal. Scene events override the result; the result fills the
  gap if no scene event arrived yet. Late replies cannot resurrect visibility, and
  delayed appearance cannot allow duplicate entry. Request tokens and a phase enum
  are unnecessary. Cancellation is silent; failures expose a retryable error.
- Left/right uses SwiftUI `AppStorage` (`wristMenuHand`). It is independent of
  immersive lifecycle and companion window persistence.
- `MacConnectionView` is reused in onboarding and Settings. Discovery and refresh
  lifetime remain in the existing gateway; these views start no extra services.

## Mounting

One `AnchorEntity` holds one `ViewAttachmentComponent`. Changing wrist changes the
anchor target and local transform, preserving the menu entity. RealityKit owns
tracking; there is no raw hand-data access, ARKit provider, or smoothing loop.
Standard SwiftUI buttons provide interaction without custom palm gestures, which
would compete with system Home/Control Center gestures.

Apple defines wrist +Y outward from the back of the hand and +Z toward the thumb.
The menu faces outward, top toward the fingers, 4.5 cm above the wrist and 12 cm
toward the forearm to leave system overlays clear. Its 320-point width is scaled
to 0.6. These are starting values for headset testing, not validated ergonomics.
The simulator uses a one-time head anchor for the same UI, with an explicit note.
The former Palm Spike scene is removed; normal window scene IDs remain unchanged.

## Verification and extension limits

Run the README checks, including `pnpm test:vision-state` and a visionOS simulator
build. The state tests cover cancellation, retry, repeated input, delayed scene
appearance, and system dismissal during both opening and closing. Existing gateway
and persistence tests continue to protect window intent and session lifetime.

Physical-device verification is deferred: check both wrists, targeting and overlay
clearance, loss/recovery of tracking, repeated mode switches, system dismissal,
reopening windows with only the wrist visible, exit with no regular windows, and
Mac disconnect/reconnect. Compilation does not establish these guarantees.

A future “Place here” feature should reuse this palette. Status displays should
reuse real available data; wrist dictation needs explicit target/microphone ownership.
A terminal cockpit would be a separate rendering project: immersive mode does not
grant arbitrary placement of ordinary windows. Keep all window actions behind the
gateway and avoid a second router, persistence layer, or general mode framework.

## References

- [Windows and spaces](https://developer.apple.com/documentation/visionos/presenting-windows-and-spaces)
- [Wrist coordinates](https://developer.apple.com/documentation/realitykit/anchoringcomponent/target-swift.enum/handlocation/wrist)
- [Privacy-preserving anchoring](https://developer.apple.com/documentation/realitykit/spatialtrackingsession)
- [System gestures](https://developer.apple.com/design/human-interface-guidelines/gestures)
