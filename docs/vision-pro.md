# Vision Pro

[Back to README](../README.md) · [Mac setup](mac-companion.md)

## Connect to your Mac

Open `apps/vision-client/SlopZooka/SlopZooka.xcodeproj` in Xcode and run the headset app. Bonjour discovers the companion. When pairing is needed, the code briefly appears centered on the Mac without taking keyboard focus. The headset focuses its six-digit input and submits automatically; it saves the credential in Keychain. The Mac menu remains a fallback. On startup, the headset tries the saved companion address before discovered alternatives, one connection attempt at a time. Pairing errors show the attempted URL so companions on different ports can be distinguished.

The display dismisses after 45 seconds, successful pairing, or an authenticated reconnection by the device that requested it. Late display requests from a recently connected device do not reopen the prompt; other devices can still pair. Repeated display requests are limited to once per minute. Manual host/IP entry remains available behind Enter address manually. A verified IP is never rewritten into an untested hostname.

## Launcher

The app uses a graphite and silver palette. Listening indicators and app icons use soft silver; native controls and the Mac companion dashboard use graphite shades to keep button labels readable. The microphone uses native visionOS glass with a neutral icon when idle and a silver waveform while listening. Motion and status text distinguish listening from idle.

The headset launcher separates **Terminals**, **Projects**, and **Frontends**, and remembers your last tab. Project search and the tool selector are visible together. **Start from a repository** appears first to create a new workspace; **Continue a workspace** appears below it to reopen an existing one. Use the launcher’s **Settings** gear for Mac connection controls and troubleshooting; connection status remains visible in the header. Terminal windows keep frontend and dictation controls visible; shell creation, details, and **Close Window** live under the actions menu.

The toolbar uses native glass controls. The larger **globe button** at the left opens workspace frontends. Its rounded corner badge shows the app count (up to **99+**) when at least one app is present. The badge is hidden at zero while the globe stays visible. Open it to inspect the workspace’s apps or discovery notices.

Terminal rows match project rows’ rounded targets, circular icons, and compact status tags. Select anywhere in a terminal row to reopen it; its tag shows connection and window state.

Frontend rows in the launcher and terminal dropdown use the same bordered, rectangular surfaces as project rows, with compact titles, single-line details, and circular icons. The launcher list sits directly on the page without an extra glass panel.

## Keyboard and zoom

Terminal input stays focused and editable for a connected physical keyboard. Automatic focus suppresses the floating keyboard; choose the **keyboard icon** in the terminal toolbar or tap inside the terminal to request it. When using Mac Virtual Display, moving the pointer into the terminal and clicking may still be necessary to transfer typing from the previous text field. Pinching a window alone does not guarantee that handoff.

Use **Interrupt** in the terminal toolbar to send Escape without changing keyboard focus. The toolbar’s **Stop** button asks for confirmation before ending the session and its attached dev servers. **Close Window** in the actions menu dismisses the window immediately and keeps the session running. WebKit editing events for Return, Backspace, and Delete are routed through the terminal's key handling. Update both apps for separate floating-keyboard control; older companions retain typing focus but may also show the floating keyboard.

Hardware arrow shortcuts preserve Option/Alt, Control, and Shift, including **Option+Up (Alt+Up)** in Codex. Update the headset app for the WebKit arrow-event fix; this also applies when your keyboard is shared from the Mac through Mac Virtual Display.

Terminal zoom ranges from **10% to 200%**. **Settings → Default terminal zoom** starts at **80%** and persists across app launches. Terminals without a custom zoom follow that default; existing scene zoom preferences are preserved. Reset Zoom applies the current saved default. Use the zoom controls in the actions menu; it stays open for repeated adjustments.

Zoom changes the terminal font size and explicitly refits the emulator and PTY while keeping the web view full size. Older Mac companions without the font-zoom bridge use a scaled logical viewport so their resize observer still refits the terminal. Update both apps for the bounded emulator/PTY grid at extreme zoom.

## Terminal notifications

Terminal bells (BEL) and desktop notification escapes (OSC 9 and OSC 777) give that terminal an orange border and an **Unread notification** badge. Tap or pinch inside the window, use its controls, or type in it to mark the notification read. Selecting another terminal does not clear it. Automatic keyboard focus and content reloads do not mark notifications read.

New alerts play a short chime anchored to the terminal window's position in the room. Bursts are limited to one chime per second per window. Reconnecting recovers missed notifications silently; replaying output or reloading content does not repeat a chime. Unread state stays with the window during the headset app's lifetime, including content reloads and reconnects.

This handles alerts emitted by the terminal program; it does not infer completion from output text or a process exit. Enable terminal notifications in your coding agent if they are disabled. Update both apps and restart an older Mac session service after ending its sessions to enable alert detection. Test the path from a shell with `printf '\a'`.

## Dictation

Look at the title above a terminal window and pinch to start voice naming. The title’s glass background, hit area, and gaze highlight share one rounded shape; selecting it opens the centered glass rename overlay. Say a name and pause, or tap **Save Name**. Whitespace becomes dashes: “Fix the login flow” becomes **Fix-the-login-flow**. The same name appears above the window and in the companion dashboard, launcher, and wrist menu. Unnamed terminals keep their original labels.

Names support up to 120 characters and stay with the Mac session across reconnects, window closure, app rebuilds, and companion restarts. The rename overlay’s **×** cancels naming; failed saves keep the draft for retry. Send, save, or discard an existing voice draft before switching voice tasks. Update both apps for shared names; an older running session service requires an explicit restart after ending its sessions.

**Settings → Persistent voice input** is off by default. Turn it on, then look at the larger glass microphone button at the terminal’s bottom right and pinch to start. A glass transcript overlay centered in the terminal and a listening border mark the destination. The microphone stays at the bottom right while the overlay remains centered in dictation, conversation, and rename modes. The listening waveform follows microphone energy and settles during silence; no audio is retained for this visual feedback. Pauses and long recordings keep appending to the same draft; **Send** submits it with Return and starts listening for the next message. Select another terminal’s microphone to switch when the draft is empty, or send/discard the draft first. The transcript overlay’s **×** releases the microphone and discards the draft.

The same explicit selection works in normal and immersive workspaces; there is no automatic head or eye targeting. Turning the setting off restores one-shot dictation, which sends after a short pause.

Listening never restores on launch. Losing the connection or scene activity pauses capture and keeps the draft; reconnecting requires **Resume** or **Retry**. Retry preserves the command ID to avoid duplicate input after an uncertain acknowledgement.

## Immersive workspace

**Settings → Immersive workspace** adds an optional wrist menu at runtime. It opens the launcher and up to three recent terminals through the same window gateway. Choose either wrist; exit from Settings or the wrist menu. Your room and SlopZooka windows remain visible while other apps are hidden. Immersion starts off on each launch. The simulator shows a stationary version of the same menu; physical wrist tracking and comfort require Vision Pro validation. See [the immersive workspace design](../.plans/2026-10-31-immersive-workspace.md) for architecture, scope, and device checks.

## Terminal lifecycle

- A workspace is a git worktree. Each workspace can have multiple independent terminal sessions.
- Opening a session attaches a viewer. Closing a window or losing the network detaches it without killing the process.
- Sessions reappear in the launcher after restarting the headset app. Reopening restores the current screen, including the alternate screen used by TUIs.
- **New Shell** adds a terminal to the same workspace. The toolbar’s **Stop** button confirms before explicitly stopping the process and its current descendants. Ending an already exited session removes its retained screen.
- Sessions survive client disconnects and menu/HTTP companion restarts. They do not survive session-service crashes/restarts or Mac reboots. Processes continue running until explicitly ended or the session service stops.
- Terminal viewers retry interrupted connections automatically, including stalled connection attempts. After detecting a restarted Mac companion, the headset refreshes visible terminal content in the same windows. If recovery still stalls, use **Reload Content** in the terminal’s actions menu or the launcher’s reload button; these preserve running sessions.
- One viewer controls keyboard input and terminal size. Additional viewers are read-only; control transfers when the controlling viewer detaches. Native dictation is an authenticated host command and is ordered with keyboard input.

## Window recovery

The companion saves the intended set of terminal and preview windows in `SLOPZOOKA_HOME/window-layouts.json`, separately for each headset installation's client ID. Update both apps to use this feature. The headset keeps a small outbox of unacknowledged open/close changes, so a disconnected close or interrupted save can be retried after reconnecting. A native rebuild over the existing installation retains that client ID; deleting the app's data creates a different client.

Every scene can start recovery, including when the launcher is closed. Existing system-restored windows resolve their content again; missing intended windows are opened once. Closing a window updates the saved layout without ending its terminal process. Backgrounding, disconnecting, or rebuilding the headset app does not close the saved windows. HTTP companion restarts preserve sessions. Sessions lost to a session-service restart remain unavailable; recovery never silently launches replacement shells. Preview windows resolve fresh gateway URLs and trust material from the Mac, including after detecting a new HTTP companion instance. Cookies and browser navigation history still belong to the WebView and do not survive native process replacement.

visionOS owns physical placement and room locking. Recovery preserves scene IDs and reuses restored scenes, but opening a missing window is not a guarantee of its previous physical position. Xcode stop/run, installation over an existing app, system-close behavior, and locked/unlocked room placement require device testing.


## Optional live surface experiment

The [live surface test runner](../experiments/surface-live-probe/README.md) builds a separate **SlopZooka Gateway Probe** from the app's real source. It pairs with an isolated companion and can open a prepared simulator preview through the existing window gateway. The companion enables these test routes only when `SLOPZOOKA_SURFACE_PROBE_MANIFEST` names a local run manifest; ordinary installations do not enable them.

The test preview is a streamed image with Reload and Close controls. Its on-screen receiver status is diagnostic; direct headset pointer/keyboard control is not implemented. The experiment's separate app identity keeps its pairing/layout state separate from your normal installation. Use the linked runbook for setup, Stop and cleanup.
