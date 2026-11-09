# Many Vision surfaces without a matching Mac desktop

Research and design update, November 9, 2026. The user wants a large spatial workspace with many apps/windows, without arranging a matching desktop on the Mac. This reopens the browser rendering strategy. No new runtime was installed or benchmarked for this note; documented capabilities below are not measured SlopZooka results. The separate [CUA responsibility decision](2026-11-09-agent-control-ownership.md) remains open.

## The Mac's display area is not the canvas limit

Apple's **desktop-independent single-window** capture includes a window's full content when covered or completely offscreen. Minimizing pauses the stream. Display-based filters have different behavior; they should not be substituted for this claim. Thus, Vision windows need not fit into a nonoverlapping arrangement on the laptop display. This does not prove arbitrary native window dimensions or reliable background rendering by every app. [Apple's window-capture demonstration](https://developer.apple.com/videos/play/wwdc2022/10155/).

Desktop hosting still creates constraints: source-window geometry, app-specific rendering/throttling, native dialogs, lock state and focus-dependent input. More windows also consume memory, rendering, encoding, network and headset decoding resources. Our [three-stream synthetic codec benchmark](2026-11-08-mac-codec-benchmarks.md) is not a measurement of dozens of live web apps or headset receivers.

Separate **host computation**, **host-visible windows**, and **Vision presentation**. The Mac can run browser renderers without displaying their pages on its desktop. Vision can arrange their outputs independently. Each page still needs a defined viewport; making its spatial panel larger need not enlarge a physical Mac window. Changing CSS viewport size, raster resolution and spatial size are separate operations, with different effects on responsive layout and text clarity.

## Browser choices

| Approach | Mac desktop dependence | Benefit | Main work or limit |
| --- | --- | --- | --- |
| Existing Chrome windows + ScreenCaptureKit | Real windows; may be covered/offscreen, but minimization matters | Reuses the tested native video path and demonstrated native Chrome control | Desktop clutter, focus contention, tab/window association; does not establish scale |
| Managed headless Chrome/Chromium + browser media | No visible browser windows needed | Own explicit page/session identities and viewport sizes without embedding an engine | Qualify a continuous media source; screenshots alone do not establish a good streaming path |
| Embedded Chromium through Electron offscreen rendering or CEF | Page output supplied by the browser engine | Direct frame/texture output, controlled lifecycle and page identity | Browser integration, updates, isolation, input/dialogs and native encoding bridge become our responsibility |
| Existing headset `WKWebView` + an agent bridge | No Mac page window or page-video stream | Native web rendering and direct user interaction in Vision | Build observation/control for the exact headset view; qualify compatibility and resource use |
| Chrome extension tab capture | Captures a tab rather than the desktop's visible pixels | Could reuse installed Chrome and its browser sessions | User-invocation/access requirements and media integration; not supplied by the inspected Codex extension |

Chrome documents that modern headless mode creates platform windows without displaying them and uses the unified Chrome implementation. It can supply invisible pages, but this is not a guarantee of efficient continuous remote presentation. [Chrome Headless](https://developer.chrome.com/docs/automation-and-testing/headless).

Electron exposes offscreen bitmaps or shared GPU textures, dirty regions and rendering/frame-rate controls. Static pages need not produce repeated frames. This makes a small owned browser host a plausible experiment; it does not require SlopZooka to fork Chromium. [Electron offscreen rendering](https://www.electronjs.org/docs/latest/tutorial/offscreen-rendering).

CEF's `CefRenderHandler` supplies view/popup painting when window rendering is disabled. Its accelerated path documents a macOS IOSurface, with callback-scoped ownership requiring the client to copy into its own texture. CEF is a native embedding candidate, not a finished browser product. [Inspected CEF interface, pinned revision](https://github.com/chromiumembedded/cef/blob/46ff67dd15839c07f1c1c919170eb70dc4f353ba/include/cef_render_handler.h).

Headset-local rendering remains a real alternative. `WKWebView` exposes snapshots and JavaScript evaluation, which are building blocks for an application-owned observation/control bridge. They do not automatically supply Playwright semantics or complete input fidelity. We would have to implement and test that bridge against the actual view, including frames and native browser UI. [WebKit snapshots](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:)), [JavaScript evaluation](https://developer.apple.com/documentation/webkit/wkwebview/evaluatejavascript(_:in:in:completionhandler:)).

Chrome `tabCapture` exposes tab media, but starting capture has user-invocation and target permission requirements. It is not an unattended arbitrary-tab capture grant. The [earlier extension investigation](2026-11-09-background-browser-control.md) found no `tabCapture` permission in the inspected Codex extension. [Chrome tab capture](https://developer.chrome.com/docs/extensions/reference/api/tabCapture).

## What an owned browser could look like

Proposed path: **workspace-bound browser page → offscreen frames → native encoding bridge → existing video transport/receiver → Vision window**. The agent controls that same page through its browser adapter; human input can address the same page when that input path is implemented. ScreenCaptureKit remains the capture source for ordinary native applications. The browser replaces the frame source, rather than requiring a second headset window manager or a new transport by default.

For Electron, the documented macOS shared handle is an `IOSurfaceRef` local to the process. Textures must be released promptly. A native bridge must manage ownership, synchronization, pixel format, possible conversion and encoder completion. Sending a raw pointer through JSON to the Swift companion is not valid cross-process sharing. Reusing the current encoder architecture is plausible; a zero-copy end-to-end path is not established. The shared-texture option is marked experimental. [Shared texture handle](https://www.electronjs.org/docs/latest/api/structures/shared-texture-handle), [texture lifecycle](https://www.electronjs.org/docs/latest/api/structures/offscreen-shared-texture), [window options](https://www.electronjs.org/docs/latest/api/browser-window).

For a headless Chrome experiment, classic CDP `Page.startScreencast` produces JPEG/PNG image events, so it is not itself an inter-frame video encoder. **Additional research lead:** the inspected protocol also has experimental `Page.startScreenRecording`/`stopScreenRecording` returning an `IO.StreamHandle`. Check availability, codec/container, live-read latency and headless support in the actual browser before using it. The declaration alone does not establish a low-latency Vision stream. [Pinned protocol source](https://github.com/ChromeDevTools/devtools-protocol/blob/b0d96c6cdf39e5583e67a3762b2815a33154455b/pdl/domains/Page.pdl).

For own-renderer pixels and browser input, this design would avoid using ScreenCaptureKit and macOS AX as the normal web path. Native app sharing and OS dialogs still need their respective providers. Headless operation also does not establish operation during lock, logout or sleep.

**Offscreen pixels do not prove independent input.** Electron documents that `webContents.sendInputEvent` requires its containing window to be focused. Do not select that API and assume invisible pages can all accept ordinary input without disturbing the desktop. Qualify browser-protocol/embedding input against the exact offscreen target, including keyboard focus, IME and popups, before choosing the host. A successful scripted DOM click alone is insufficient. [Electron input contract](https://www.electronjs.org/docs/latest/api/web-contents#contentssendinputeventinputevent).

## Keep the abstraction small

The common object should remain the **actual content target** with its observation, input and presentation capabilities. A native window ID is one provider's binding; it should not be mandatory for every browser or simulator target. Keep browser viewport dimensions, video dimensions and Vision placement separate. Existing services own workspace associations, the browser provider owns its pages/profiles, and `WindowGateway` owns presentation. No parallel window registry is needed.

This also preserves the ownership decision: either terminal Codex or Pi can invoke the selected provider. However, native Codex `getApp` control of Chrome does not prove control of an invisible embedded/headless page. Reusing its specialized browser runtime still has the [previously observed authorization/attachment constraints](2026-11-09-browser-runtime-options.md). Choosing our own Chromium host does not automatically solve that adapter dependency or establish compatibility with its extension.

Use native capture for arbitrary Mac applications, device-owned frames/input where suitable for simulators, and investigate a browser-owned or headset-local path for web surfaces. This is a proposed division of responsibilities, not approval to implement several browser backends at once. A virtual display could help a native application that needs display geometry, but is not required for browser-owned frames and does not by itself supply independent input sessions.

## Resource policy and maintenance are the real tradeoffs

An expansive workspace can retain many surfaces while rendering fewer at full rate. Candidate behavior: keep interactive/actively watched surfaces responsive, reduce work for background surfaces, and retain a clearly marked last image when presentation is paused. Preserve sessions and unfinished forms. Pausing video must not silently close a page or imply that its JavaScript has stopped. A static page with no changed frames is also different from a disconnected source.

Prefer explicit selection/pinning and available client lifecycle signals initially; do not assume access to eye gaze or perfect knowledge of what the user sees. Refresh before an agent acts and before presenting resumed content as current. Qualify 1, 4 and 8 active surfaces among a larger retained set before promising a capacity. These are test points, not established limits.

Keeping hidden pages responsive can increase resource use and change visibility semantics. Electron documents how background throttling affects visibility; its recent fix for re-enabling throttling also shows why that behavior needs version-specific testing. [Visibility behavior](https://www.electronjs.org/docs/latest/api/browser-window#page-visibility), [throttling fix](https://releases.electronjs.org/pr/54311).

An owned browser also means owning updates and browser behavior: session/profile isolation, authentication and popups, uploads/downloads, clipboard/IME, permissions and crash recovery. Embedded remote pages must remain isolated from companion privileges. Electron specifically calls for current releases, sandboxing, context isolation and no Node integration for remote content. Treat this as ongoing product maintenance when comparing an installed Chrome host against embedding. [Electron security guidance](https://www.electronjs.org/docs/latest/tutorial/security).

## Narrow next comparison

The new requirement changes the question from “can we stream Chrome?” to “can several independently controllable web surfaces live in Vision without disrupting the laptop?” Proposed follow-up, not a test already run:

1. Use one existing native Chrome/SCK surface as a baseline and one disposable browser-owned offscreen surface. Choose a single candidate after a short media/adapter check; do not build Electron and CEF simultaneously.
2. Verify separate viewport sizes, fresh observations and input, an iframe, a popup/login transition, and an unfinished form surviving pause/resume. The laptop should remain usable without raising/rearranging its windows.
3. Retain 10–20 pages and vary the active set through 1/4/8. Measure process memory, CPU/GPU work, frame age, input latency, encoder/network cost and recovery. Distinguish idle apps from animated content.
4. Connect the winning candidate to the existing Vision receiver. Measure headset decoding/compositing, readable text, actual scene behavior and resume latency. Mac-only results cannot establish headset capacity. Test lock separately if needed.

The recommendation to evaluate is **an owned browser host using an existing Chromium distribution or embedder**, with no Chromium fork. Desktop-window capture remains useful for interoperability and the first integration. It should not become the assumed backing for every spatial web surface. Many-window scale, efficient browser media, authentication/input completeness and control-runtime compatibility remain unresolved.
