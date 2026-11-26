# Terminal scrolling on Vision Pro

[Vision Pro guide](vision-pro.md) · [Architecture](architecture.md)

## What scrolls today

A SlopZooka terminal is a live PTY renderer. `WindowScene` hosts the native
scene. `TerminalWindowView` uses the payload from `WindowGateway` to present
the first-party `CompanionWebView`. The Mac serves the renderer and owns the PTY.
On transport-v1 connections, the terminal page and its WebSocket use the headset's route-owned
loopback origin. The native adapter forwards the connection to the Mac over Local
Network or Direct. Older companions use their LAN origin.

There are three different paths:

1. **Read terminal history.** PTY output feeds the Mac session service's headless
   xterm and its cursor-based replay. On attach, the client can receive a
   serialized screen checkpoint with up to 1,000 scrollback lines. In the WebView,
   `TerminalConnection` writes ordered output to browser xterm and acknowledges
   rendering. xterm owns the current buffer and viewport. Moving that viewport is
   local to this viewer, with no Mac round trip, even when the Mac is producing
   output or another viewer owns the writer. History is bounded and can be
   trimmed, reflowed on resize, or replaced by a reconnect checkpoint.
2. **Scroll inside a terminal app.** When WebKit delivers a DOM wheel over the
   terminal, xterm 6 normally moves its local viewport. With a wheel-capable
   mouse-reporting mode such as DEC 1000, xterm instead uses the event's
   coordinates, direction and modifiers to produce a terminal mouse report. SGR
   mode (1006) uses `onData`. Without wheel reporting, xterm can translate wheel
   movement in the alternate buffer to Up/Down cursor sequences. In these cases,
   `TerminalConnection` accepts input only while attached, running and writable.
   The Mac checks pairing and origin at `/ws`, forwards the message to the private
   session service, and `SessionManager.input` checks the writer again before
   writing to the PTY. The program decides what the input does. Default legacy
   mouse encoding uses xterm's `onBinary` and the current connection subscribes
   only to `onData`. Legacy byte-preserving transport would need its own design
   and tests. [xterm terminal API](https://xtermjs.org/docs/api/terminal/classes/terminal/) · [xterm terminal sequences](https://xtermjs.org/docs/api/vtfeatures/) · [xterm 6 mouse source](https://github.com/xtermjs/xterm.js/blob/6.0.0/src/common/services/CoreMouseService.ts)
3. **Scroll a preview.** `BrowserWindowView` hosts either a web page in its own
   WKWebView, where WebKit and the page handle scrolling, or a
   `NativePreviewView` that renders captured Mac pixels. The captured path runs
   from ScreenCaptureKit through the Mac's H.264 encoder, authenticated
   `/api/window-stream/` upgrade, and headset decoder. Its reverse traffic is
   media flow control. Scrolling a capture would require a separate Mac control
   capability. Mac Virtual Display is a separate system surface, including when
   it shares a keyboard or pointer with the headset. [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) · [Mac Virtual Display](https://support.apple.com/en-us/118521)

## What the platform exposes

- visionOS chooses the hit target for indirect pinch and drag. Apps receive
  interaction events through the usual UI frameworks. System hover can give
  feedback without exposing continuous gaze or requiring hand-tracking
  permission. A pinch used to start a drag is different from a two-hand
  magnification gesture. [Apple gestures](https://developer.apple.com/design/human-interface-guidelines/gestures/) · [visionOS input privacy](https://developer.apple.com/documentation/visionos/adopting-best-practices-for-privacy)
- UIKit's `UIPanGestureRecognizer.allowedScrollTypesMask` can opt in to both
  continuous trackpad and discrete wheel input. Scroll events can drive a
  recognizer with zero touches. Apple documents the recognizer APIs and
  visionOS indirect input support. The event routing for this particular view
  and the pointer-sharing path still needs physical testing. [UIKit scroll mask](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask) · [Indirect input events](https://developer.apple.com/documentation/bundleresources/information-property-list/uiapplicationsupportsindirectinputevents)
- visionOS 26 offers system-managed, edge-based Look to Scroll for qualifying
  scroll views. Apple exposes it through SwiftUI's `scrollInputBehavior`, UIKit's
  `UIScrollView.lookToScrollAxes`, and SwiftUI WebKit's
  `webViewScrollInputBehavior`. UIKit documents size and scene-count limits.
  A real scrollable range is needed. SlopZooka's terminal document fits the
  window, with root overflow hidden, and xterm 6 uses an internal logical
  viewport. Enabling Look to Scroll on the outer view would not establish
  a mapping to terminal history or guarantee a DOM wheel event. [Apple scroll views](https://developer.apple.com/design/human-interface-guidelines/scroll-views/) · [UIKit Look to Scroll](https://developer.apple.com/documentation/uikit/uiscrollview/looktoscrollaxes) · [SwiftUI WebKit](https://developer.apple.com/videos/play/wwdc2025/231/) · [xterm 6 viewport source](https://github.com/xtermjs/xterm.js/blob/6.0.0/src/browser/Viewport.ts)

## Prototype and tradeoffs

Pinch-drag on the terminal body is on by default. The body recognizer accepts
vertical pans from direct and indirect UIKit touches. The renderer enables it while a
normal buffer has history and terminal mouse tracking is off. Session actions
can disable it per window when a user wants ordinary WebKit drag behavior.
The pointer and wheel paths stay with WebKit. **Show Scrollback Strip** adds an
optional separate hit target with VoiceOver page steps. UIKit pan translation
becomes a signed fraction of the view height.
The terminal bridge has at most one JavaScript call in flight and caps pending
movement at four viewport heights. The browser rechecks body drag eligibility
when movement arrives, so a delayed drag respects the current terminal mode.
It accumulates fractional rows and uses xterm's public buffer and scroll APIs.
The active buffer and current fitted grid determine the effect. The strip leaves alternate screens alone
and works in read-only views of a running terminal. It gives VoiceOver a named
adjustable element with page increments. Both devices need the updated build.
The two preferences are per scene. Physical testing still needs to establish
how visionOS routes pinch-drag alongside WebKit taps and text selection.

| Approach | Benefit | Cost or open question |
| --- | --- | --- |
| Dedicated native pan strip | Local feedback, small change, no competition with xterm's selection and mouse modes | The separate target takes window width and refits the grid when toggled. Movement is row-based. The prototype adds neither custom inertia nor a history-position indicator. |
| Real native or DOM scroll view synchronized with xterm | Could provide system momentum, indicators and an opt-in Look to Scroll reading mode | Needs a real range mapped to `baseY`/`viewportY`, explicit follow-live behavior, and testing when output trims history or resize reflows lines. Must prevent two-way feedback and wresting focus from xterm. |
| Pinch-drag over the terminal text | Default interaction uses the full surface for local history | Vertical pinch-drag takes priority over the WebView's scroll pan where local history is eligible. Check selection, focus, and the floating keyboard on device. |
| Translate drag to terminal-app wheel | Potential path to full-screen apps | App input needs accurate cell coordinates and defined behavior for alternate screens, protocol mode, modifiers, discrete and continuous deltas. App response costs a transport round trip plus PTY work and rendering. |
| Native transcript or terminal renderer | A separate transcript reader could use a standard accessible ScrollView. A native renderer could integrate with the OS throughout. | A transcript duplicates sensitive text and has to represent trims, styles, and wrapped lines. A full renderer also needs terminal emulation, selection, accessibility, keyboard and protocol parity. |
| Inject Mac scroll events for capture | Could operate apps that only exist on the Mac | Screen Recording and Mac event-posting access are separate. A capture source ID is not input authority. Target identity, focus, occlusion, coordinate mapping, revocation, and source disappearance all affect safe delivery. Feedback adds Mac event dispatch, app paint, capture, encode, transport and decode. [Core Graphics event posting](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)) · [macOS event-posting access](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()) |

Local scrollback sends no gaze data, scroll event, command bytes or credentials to the
Mac. It uses the first-party terminal document and clears queued movement when
disabled, inactive, or no longer running. Showing the strip can trigger the existing
fit/resize path for the current writer. There is no new permission prompt or
per-event logging. Keeping gaze-triggered movement local to reading is especially
important because wheel reports and cursor keys can change a running program.

## Verification and next experiments

The real macOS WebKit checks exercise fractional movement, bounds, fitted rows,
read-only history, alternate-screen isolation, detach, and input focus. Dispatched
DOM wheel events verify xterm's existing arrow and SGR mouse output through the
browser transport. The visionOS simulator build checks the UIKit and WebKit
integration at compile time. Physical pinch, trackpad momentum, VoiceOver
focus, and scroll latency still need device checks.

1. On Vision Pro, open two terminals spanning several pages of output and
   enable the optional strip in one. Try indirect pinch-drag in both directions, direct
   touch if within reach, mouse wheel, two-finger trackpad scroll, and pointer
   sharing with Mac Virtual Display. Check direction, small deltas, release,
   focus and window targeting. Compare with a stock scroll view on the same
   device. Repeat with VoiceOver and verify the page actions and spoken label.
2. Repeat with selection or the floating keyboard active, with continuous
   output, at different font sizes, and with shell, less, Vim, and tmux. Check
   read-only, reload, and reconnect. Compare the strip and the terminal body.
   Check SGR and legacy mouse modes separately. Confirm that a second terminal
   stays put and no extra PTY input appears when using the strip.
3. If the strip is reliable, prototype a native scroll view in an explicit
   history-reading mode using the xterm buffer range and a return-to-live
   action. Measure input-to-visible movement with the same workload for both
   variants. Capture bounded timing histograms and frame counts without storing
   gaze, coordinates, terminal text, or input bytes. Qualify Look to Scroll
   separately with system settings, window sizes, and VoiceOver.
4. Keep terminal app mouse input and remote capture control separate. For
   terminal apps, favor real WebKit wheel delivery and xterm's encoding over
   hand-built terminal sequences. For capture, evaluate source-scoped,
   user-revocable authorization and target correctness before adapting Mac
   event posting.
