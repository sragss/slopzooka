# Vision Pro

[Back to README](../README.md) · [Mac setup](mac-companion.md)

## Connect to your Mac

Open `apps/vision-client/SlopZooka/SlopZooka.xcodeproj` in Xcode and run the headset app. Bonjour discovers the companion. When pairing is needed, the code briefly appears centered on the Mac without taking keyboard focus. The headset focuses its six-digit input and submits automatically; it saves the credential in Keychain. The Mac menu remains a fallback. On startup, the headset reconnects using the saved method for the selected Mac. Initial Local Network discovery tries candidate addresses one at a time; a previously selected paired Mac is not replaced by another discovered Mac automatically. Pairing errors show the attempted URL so companions on different ports can be distinguished.

The display dismisses after 45 seconds, successful pairing, or an authenticated reconnection by the device that requested it. Late display requests from a recently connected device do not reopen the prompt; other devices can still pair. Repeated display requests are limited to once per minute. Manual host/IP entry remains available behind Enter address manually. A verified IP is never rewritten into an untested hostname.

Pairings are remembered by Mac identity. Existing pairings migrate automatically; a new address needs pairing once before it can use that Mac’s credential. During a connection loss, the launcher shows **Reconnecting to your Mac…** and retries its refresh. Switching the accepted route refreshes existing terminal and preview content while keeping their window and session identities. Switching Macs clears the previous Mac’s projects, repository owners, and frontend listing while the new catalogs load.

Pairing stays on the accepted Mac after an unsuccessful address change. Project, workspace, and repository-owner listings load independently, so one slow request does not hold up the others.

## Connection method

In **Settings → Connected Mac**, choose **Local Network** (the default) or **Direct to Mac (Experimental)**. Local Network uses the existing Wi-Fi/LAN path and supports web previews. Direct uses a nearby Mac's peer connection, requires macOS 15 or later, and supports control, terminals, and experimental native Mac window previews. Keep Wi-Fi enabled on both devices. Initial pairing must happen over a trusted Local Network with the updated companion; Direct reuses that pairing afterward. Travel, cold startup without an access point, and sleep/wake still need device qualification.

The choice is remembered for each paired Mac on this headset. A failed Direct connection stays on Direct: use **Try Again** or explicitly choose **Use Local Network**. The app does not silently switch methods. Manual IP/hostname entry belongs to Local Network.

Changing methods reconnects the existing windows while Mac terminals keep running. Web previews show an unavailable placeholder on Direct; their catalog entries remain visible with a reason. A known unavailable preview waits for a supported connection instead of repeatedly trying to open. Switching back reloads still-open previews and may lose unsaved in-page edits. A preview closed while unavailable stays closed. From a disconnected window, **Open Launcher → Settings → Connected Mac** provides the same recovery controls.

## Launcher

The app uses a graphite and silver palette. Listening indicators and app icons use soft silver; native controls and the Mac companion dashboard use graphite shades to keep button labels readable. The microphone uses native visionOS glass with a neutral icon when idle and a silver waveform while listening. Motion and status text distinguish listening from idle.

The headset launcher separates **Terminals**, **Projects**, and **Frontends**, and remembers your last tab. Project search and the tool selector are visible together. **Start from a repository** appears first to create a new workspace; **Continue a workspace** appears below it to reopen an existing one. Use the launcher’s **Settings** gear for Mac connection controls and troubleshooting; connection status remains visible in the header. Terminal windows keep frontend and dictation controls visible; shell creation, details, and **Close Window** live under the actions menu.

**Codex threads** appears last under Projects: the 25 most recently updated saved threads on the selected Mac, with search across those titles and folders and a refresh button. Select one to resume in its original folder, including folders outside SlopZooka workspaces. Repeated opens reuse its running SlopZooka terminal. Missing folders cannot be resumed. Resumed terminals exit with Codex; **New Shell** opens a separate shell in the same folder. Codex sessions running in other apps are not tracked here.

The toolbar uses native glass controls. The larger **globe button** at the left opens workspace frontends. Its rounded corner badge shows the app count (up to **99+**) when at least one app is present. The badge is hidden at zero while the globe stays visible. Open it to inspect the workspace’s apps or discovery notices.

Terminal rows match project rows’ rounded targets, circular icons, and compact status tags. Select anywhere in a terminal row to reopen it; its tag shows connection and window state.

Frontend rows in the launcher and terminal dropdown use the same bordered, rectangular surfaces as project rows, with compact titles, single-line details, and circular icons. The launcher list sits directly on the page without an extra glass panel. Choose **Add URL** to enter an address in a focused sheet. URL edits update all frontend lists for that Mac together. Windows connected to another Mac keep that Mac's listing; a slow terminal connection does not hold up frontend discovery.

In preview windows, VoiceOver identifies the reload and close controls as **Reload preview** and **Close preview**. Status messages carry the meaning of their adjacent decorative icons.

## Keyboard and zoom

Terminal input stays focused and editable for a connected physical keyboard. Automatic focus suppresses the floating keyboard; choose the **keyboard icon** in the terminal toolbar or tap inside the terminal to request it. When using Mac Virtual Display, moving the pointer into the terminal and clicking may still be necessary to transfer typing from the previous text field. Pinching a window alone does not guarantee that handoff.

Physical **Control-C** sends the terminal interrupt byte through the ordinary input connection. It interrupts the foreground command and keeps the shell/session running. WebKit Control-letter shortcuts (including Control-A/D/E/L/Z) use the same normalization as hardware arrows when the headset omits legacy key codes. Read-only viewers remain read-only; Command/Option modifiers and composition are preserved.

Use **Interrupt** in the terminal toolbar to send Escape without changing keyboard focus. The toolbar’s **Stop** button asks for confirmation before ending the session and its attached dev servers. **Close Window** in the actions menu dismisses the window immediately and keeps the session running. WebKit editing events for Return, Backspace, and Delete are routed through the terminal's key handling. Update both apps for separate floating-keyboard control; older companions retain typing focus but may also show the floating keyboard.

Hardware shortcuts preserve Shift, Control, Option/Alt, and Command when WebKit omits legacy key codes, including Shift-Tab, Home/End, Page Up/Down, and F1–F12. Shift/Caps Lock text and punctuation use the committed text from WebKit, including when no `keypress` arrives, without duplicating input already sent by xterm. Committed Option characters retain their native text; dead keys and IME composition remain owned by xterm. Update both apps for these fixes.

Fn/Globe alone sends no terminal bytes. Function or navigation keys produced by Fn work when delivered to the app; macOS/visionOS shortcuts consumed by the system remain system-owned. The terminal keeps xterm’s normal key encoding, so modifiers that its classic protocol cannot distinguish are not assigned invented escape sequences.

Terminal zoom ranges from **10% to 200%**. **Settings → Default terminal zoom** starts at **80%** and persists across app launches. Terminals without a custom zoom follow that default; existing scene zoom preferences are preserved. Reset Zoom applies the current saved default. Use the zoom controls in the actions menu; it stays open for repeated adjustments.

Zoom changes the terminal font size and explicitly refits the emulator and PTY while keeping the web view full size. Older Mac companions without the font-zoom bridge use a scaled logical viewport so their resize observer still refits the terminal. Update both apps for the bounded emulator/PTY grid at extreme zoom.

## Terminal notifications

Terminal bells (BEL) and desktop notification escapes (OSC 9 and OSC 777) give that terminal an orange border and an **Unread notification** badge. Tap or pinch inside the window, use its controls, or type in it to mark the notification read. Selecting another terminal does not clear it. Automatic keyboard focus and content reloads do not mark notifications read.

New alerts play a short chime anchored to the terminal window's position in the room. Bursts are limited to one chime per second per window. Reconnecting recovers missed notifications silently; replaying output or reloading content does not repeat a chime. Unread state stays with the window during the headset app's lifetime, including content reloads and reconnects.

SlopZooka reports native scene deactivation to terminal programs as focus-out. Codex normally emits notifications only while its terminal is unfocused. Looking or walking away does not necessarily deactivate a visionOS window; if you also want alerts while it retains focus, optionally start Codex with `codex -c 'tui.notification_condition="always"'`. SlopZooka launches Codex normally and does not override its notification settings. See the [Codex TUI settings](https://learn.chatgpt.com/docs/config-file/config-advanced#tui-options).

This handles alerts emitted by the terminal program; it does not infer completion from output text or a process exit. Enable terminal notifications in your coding agent if they are disabled. Update both apps and restart an older Mac session service after ending its sessions to enable alert detection. Test the path from a shell with `printf '\a'`.

## Dictation

The header above each terminal shows **project / workspace / window** on the same rounded glass surface. Project is the repository name and cannot be edited. Workspaces default to a short UTC creation timestamp such as **nov-09-2104**. Window defaults are assigned per tool within each workspace: **codex**, **codex2**, **claude**, **terminal**, and so on. Labels remain stable when windows close, sessions are removed, or the HTTP companion restarts; existing custom window names are preserved.

The diagonal dividers also bound the full-height hover regions: workspace fills between the slashes, and window fills through the rounded right edge. Naming is available independently of terminal keyboard/renderer readiness.

Look at the workspace or window segment and pinch to use the existing centered voice rename overlay. Say a name and pause, or tap **Save Name**. Whitespace becomes dashes. A workspace rename updates its sibling windows and project listings; a window rename changes only that session. The launcher, companion dashboard, and wrist menu show the same naming context. These are display labels: renaming never changes the Git branch, worktree path, window identity, or running process.

Names support up to 120 characters and stay with the Mac session across reconnects, window closure, app rebuilds, and companion restarts. The rename overlay’s **×** cancels naming; failed saves keep the draft for retry. Send, save, or cancel an existing voice draft before switching voice tasks. Update both apps for shared names; an older running session service requires an explicit restart after ending its sessions.

Look at the large glass microphone at the terminal’s bottom right, then **pinch and hold** while speaking. Release to finish transcription. A silver bar fills around the centered transcript box for **three seconds**, then the message sends with Return. Tap **×** during the countdown to cancel. A short mechanical click and a soft border pulse confirm delivery; the transcript fades out in place. The microphone stays off until your next hold.

Pauses and long recordings keep appending to the same draft while you hold. The waveform follows microphone energy; no audio is retained for this visual feedback. A listening border marks the destination. The same control works in normal and immersive workspaces, with no automatic head or eye targeting. Renaming and bug reports keep their own save/review controls.

Listening never restores on launch. Losing the connection or scene activity cancels a pending countdown and keeps the draft. Reconnect, then hold the same microphone to continue, or use **Send**, **Retry**, or **×** on the preserved draft. Retry preserves the command ID and destination to avoid duplicate input after an uncertain acknowledgement. Reconnecting never starts the microphone or sends on its own.

## Immersive workspace

**Settings → Immersive workspace** adds an optional wrist menu at runtime. It opens the launcher and up to three recent terminals through the same window gateway. Choose either wrist; exit from Settings or the wrist menu. Your room and SlopZooka windows remain visible while other apps are hidden. Immersion starts off on each launch. The simulator shows a stationary version of the same menu; physical wrist tracking and comfort require Vision Pro validation. See [the immersive workspace design](../.plans/2026-10-31-immersive-workspace.md) for architecture, scope, and device checks.

## Terminal lifecycle

The terminal’s **…** popover uses separate rounded action rows and circular zoom
buttons, with space between their gaze targets. **Report a Bug** opens a native
voice sheet after the popover closes, including while the terminal is disconnected.

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

Reloading a preview keeps its current content available while reconnecting. Reloading again, or closing and reopening it, starts fresh recovery without waiting for an older stalled request. Late rename replies cannot restore a terminal whose session has ended.

visionOS owns physical placement and room locking. Recovery preserves scene IDs and reuses restored scenes, but opening a missing window is not a guarantee of its previous physical position. Xcode stop/run, installation over an existing app, system-close behavior, and locked/unlocked room placement require device testing.

## Diagnostics

Native actions, state changes, errors, and terminal WebView events are buffered
locally and uploaded through the existing paired connection to their Mac. Each
Mac receives its own events even when another Mac is selected. The buffer is
limited to 8 MiB in memory; reconnect retries preserve event identity, while an
app restart loses unsent history. Logging does not wait for the network before
performing an action. See [Mac diagnostics](mac-companion.md#diagnostics) for
retention and capturing raw evidence from `SLOPZOOKA_HOME/logs` before logs rotate. The incident timestamp
is an anchor for future bug-report tooling; capture does not filter device events
by it. Only the debug panel observes the shared recent-entry ring, so transport
and outbox state do not invalidate terminal views.

Connection diagnostics include the selected method, route revision, action ID,
and first native failure at each stage (such as TLS setup or admission). Failed
uploads remain queued for that Mac and follow its replacement connection; they
never switch connection methods on their own. After reproducing a disconnected
failure, reconnect before capturing the report so the Mac can collect that
headset's buffered evidence. Repeated byte-channel failures are sampled, so a
quiet log is not evidence that the connection recovered.

For typing lag, note the time, connection method, and whether you are using Mac
Virtual Display keyboard sharing or a keyboard connected directly to Vision Pro.
Terminal diagnostics summarize input delivery, the trip to the Mac's PTY service,
and browser output queues and parsing without recording typed text. Reproduce in
both a quiet shell and a busy terminal, then capture from that terminal's Mac.
See [investigating terminal lag](mac-companion.md#investigating-terminal-lag) for
the measurements and their limits.

In a terminal’s **… → Report a Bug**, a native sheet starts listening with the same
microphone orb used by terminal dictation and title renaming. Pauses keep your
draft. Tap the orb to pause and edit, or **Review Public Report** to finish
transcription and inspect the exact public text. An existing unsent terminal
voice draft is paused and preserved; finish/discard it before dictating the
report, or type the report instead. Denied microphone permission still allows typing.

The terminal’s Mac saves a diagnostic snapshot after the headset attempts to flush
its outbox. Logs stay local. **Create Public Issue** posts to `sragss/slopzooka`
using the Mac’s GitHub credentials, showing the account before submission. Nothing
is published on a pause or when opening the sheet. If credentials or the Mac are
unavailable, **Review on GitHub** opens your prepared public draft in the browser.
Expired reviews and connection/account rejections keep your text and offer **Edit**
or **Review Again**. Re-review refreshes the account and requires another explicit
**Create Public Issue** action. Timeouts, cancellation during submission, and other
uncertain responses keep native resubmission disabled; check existing issues
before using the browser fallback to avoid duplicates. See [bug reports](mac-companion.md#bug-reports) for privacy,
local snapshot access, and retention.

## Mac window previews (experimental)

A companion launched with `SLOPZOOKA_WINDOW_PREVIEWS=1` adds **Mac windows** to
its launcher frontend list. Select a window to share its full content, including
any Simulator toolbar. The Mac supplies the aspect ratio, so an iPhone Simulator
can open as a tall preview. The native video surface uses continuous rounded corners, consistent with web previews.
Reload and the actions menu sit above the content,
leaving the bottom resize handles clear. **Close Preview** is in that menu;
closing a preview does not quit the source app or end any terminal.

Native previews use the selected Local Network or Direct to Mac route. Local
Network capture requires macOS 14+; Direct requires macOS 15+ and prior LAN pairing.
Two simultaneous native streams, app restart and return to LAN have passed a
physical-device check. Direct remains experimental; travel, sleep/wake and capacity
are not yet qualified. Native capture reports Screen
Recording permission and offers **Allow Screen Recording on Mac** and **Open Mac
Privacy Settings**. Complete the system prompt on your Mac. The signed provider's
permission identity still needs final device qualification; development or ad-hoc
builds may need permission again after rebuilding. Screen capture itself does not
require Accessibility. Computer-use control has its own permission requirements.

These previews carry video. Interact through the Mac app or an agent's existing
Mac computer-use tools. A locked Mac, closed source, revoked permission, or stalled
stream clears the image and reports its state. Temporary stream interruptions get
three bounded reconnect attempts; Reload remains available. After the capture
provider restarts, select the current window again: SlopZooka will not silently
substitute another window with a similar title. Locked-desktop
fallbacks, attention-based quality changes, and automatic app launching are later
steps. The feature stays off by default during this experimental rollout.
