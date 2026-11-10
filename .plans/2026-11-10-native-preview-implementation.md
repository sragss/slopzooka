# Native window preview implementation

Stacked on transport draft [PR #54](https://github.com/sragss/slopzooka/pull/54),
branch `feat/native-window-previews`. The research worktree remains untouched.
This is rollout step 1: manual window previews before the terminal MCP and Pi.

## Slice and ownership

- One signed native Mac provider enumerates exact windows, reports capture
  permission/desktop availability, and captures ScreenCaptureKit → hardware H.264.
  No AX/input control or app launch in the capture provider.
- Extend the existing frontend catalog and resolver with native window sources.
  Existing web responses remain compatible. One canonical presentation decision
  gates catalog and Open. Start with LAN; Direct media remains unavailable until
  qualified with the integrated receiver.
- Preserve the existing Preview scene and stable layout records. `WindowGateway`
  resolves web or native content; `WindowScene` owns native geometry requests.
  Source geometry determines aspect ratio. Capture resolution never determines
  physical window size; full-window Simulator capture is labeled honestly.
- Control uses the existing authenticated companion route. A single authenticated
  HTTP upgrade bridges a fixed native provider stream through that route. Node
  forwards bounded binary buffers without parsing, encoding, or dispatching video
  frames. Encoded media, acknowledgements, and decoder state remain native. No
  second discovery, pairing, source API, or arbitrary-port tunnel.
- A preview connection is a viewer subscription. Closing it releases capture
  resources when the last viewer leaves; it never quits the source application.
  Independent viewers cannot block one another or share close authority.

## Media gate before widening the UI

Use a versioned, bounded binary packet format and H.264 only. Limit native
receive buffering and per-viewer outstanding frames; require fresh keyframes
when frames are skipped or a connection resets. Use receiver acknowledgements
and a finite stall deadline, not successful socket sends as proof of display.
A stalled viewer is disconnected instead of accumulating obsolete video. A
receiver returning after inactivity discards old buffered frames and reconnects.
Do not compare unrelated device clocks or claim renderer enqueue equals display.

Automate malformed/fragmented packets, keyframe recovery, format changes,
independent viewers, constrained delivery, receiver stalls, and final-data/EOF
handling. Exercise actual VideoToolbox output and native sample reconstruction.
Then prepare one focused signed-app/headset slot for a native fixture and Simulator,
source loss, permission repair, visible freshness, and phone-shaped presentation.
Physical source/render quality and system placement remain device gates.

## Identity and unavailable state

Bind to observed window and owning process identity, never title matching. A
closed/replaced source becomes unavailable; do not silently choose a similar
window. If identity cannot be proven after provider restart, require reselection.
Keep permission missing, desktop locked, source gone, unsupported route, and
stream stalled distinct. Detect permission without prompting during enumeration;
request/repair only from an explicit user action. Permission ownership must be
verified under the final signed bundle.

No model is responsible for source dimensions, transport choice, stream lifetime,
or permission inference. The later MCP is a thin caller of these same operations.

## Implemented candidate

The first manual slice is behind `SLOPZOOKA_WINDOW_PREVIEWS=1` (off by default).
The launcher lists Mac windows alongside web sources. WindowGateway uses the same
Preview record/scene and persists only source identity. Companion geometry produces
an initial aspect request; subsequent aspect changes preserve the current diagonal,
and a per-scene preference prevents reload from resetting user sizing. Native CUA
control remains separate; this slice is video-only.

Native media uses the same route-owned channel lifetime as other companion traffic.
The signed `window-host` child is private to the Node owner. Typed control is bounded
stdin/stdout IPC; one-time media tickets are never returned to the headset. The Node
bridge only pipes bytes through an authenticated, fixed upgrade. Each viewer owns a
capture and encoder, with eight viewer slots, two frame credits, one encode, one
latest raw image, and one send in flight. Do not call eight-viewer hardware capacity
proven. Frame ACKs follow renderer enqueue, not physical presentation. Separate state ACKs
keep initial capture warmup alive and bound idle disconnected viewers; they cannot
release frame credit. Capture startup is capped at ten seconds, encode/credit stalls
at one second, and missing idle acknowledgements at two seconds. Heartbeats are
omitted while video is flowing.

Source geometry is full-window geometry, not an inferred iPhone screen crop. The
capture encoder currently caps the longest edge at 1920 pixels, 30 fps, 8 Mbps,
hardware H.264 with reordering disabled. These are starting values to qualify, not
measured quality/performance claims. Permission and lock observations fail to an
unavailable state, not cached screenshots presented as live. Lock detection uses
macOS session metadata plus capture/source health; it needs requalification after
OS changes. Provider restarts require source reselection; process/window IDs are
observations within a provider epoch, not a permanent OS identity guarantee.

## Focused device gate

Use isolated Mac/headset test identities, home, port, and pairing; preserve the
installed SlopZooka and its terminal sessions. No new install, permission prompt,
or lock operation was performed as part of this implementation's automated checks.

1. Final certificate-signed provider: confirm the actual app named in Screen
   Recording settings, detection, explicit request/repair, revocation, and recovery.
2. Native fixture plus iPhone Simulator: open both manually; verify fresh counters,
   readable text, motion, initial phone aspect, rotation/resize, and scale preserved
   across Reload. Confirm a covered source still updates.
3. Close/reopen one preview with launcher closed. Keep the other fresh and verify
   the source apps/PTYs remain alive. Temporarily interrupt a media channel; verify
   bounded recovery and no old-frame burst. A helper restart must offer reselection,
   not silently bind the old record to another window.
4. Lock only in an agreed test slot: both streams must clear with a truthful state;
   unlock/Reload restores a still-valid source. This does not qualify the earlier
   separate locked-desktop fallback research as part of this implementation.
5. Switch Direct/Local Network: native and web unavailable on Direct, terminals stay
   usable, no silent LAN fallback, same desired preview intent on return to LAN.

The already-open transport PR still needs its short physical EOF-recovery recheck:
restart only its test helper, launcher closed, independently ACK both terminals
without a connection-method toggle. Combine that with this slot when convenient.
Only after these gates should we enable the manual preview slice by default and
add the thin terminal MCP. Chrome ownership and the Pi coordinator remain later.
