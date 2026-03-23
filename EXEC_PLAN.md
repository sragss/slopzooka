# EXEC_PLAN

## Purpose

This document turns the product idea in `PLAN.md` into a buildable v0 plan. The goal is to keep the Vision Pro app thin, move the risky terminal/process work onto a nearby Mac, and force early testing around the parts that are most likely to break.

## Review of `PLAN.md`

What is strong in the current plan:

- The user problem is clear: spatially organized coding contexts are more valuable on Vision Pro than a single giant display.
- The desired core loop is concrete: launch app, create cluster, open TUI/browser/terminal windows around the room, and keep them tied to one repo workspace.
- The instinct to keep the headset app "dumb" and let the Mac do the real terminal work is correct.

What is still missing:

- Whether v0 is a shared-space windowed app or a more immersive app.
- Whether the headset talks to the Mac over raw SSH or through a custom companion service.
- How terminal rendering works on visionOS.
- What the first input model is for prompts and dictation.
- How workspaces are created, named, resumed, and destroyed.
- How the app will actually be tested in simulator versus on real hardware.

## Recommended v0 Decisions

These are the decisions I recommend we lock in now.

### 1. Build a native `visionOS` app, but keep v0 window-first

Use `SwiftUI` scene management and target the normal shared-space productivity model first. Do **not** make v0 a full immersive experience.

Why:

- Apple positions visionOS apps around windows, volumes, and spaces, and explicitly recommends starting with a window and adding immersion only where it is useful.
- Your product is fundamentally a productivity/multi-window app, not a game or cinematic environment.
- Shared space is the fastest route to something usable and testable.

Implication:

- v0 uses multiple windows in shared space.
- No full immersive environment in v0.
- No `RealityKit` dependency unless we discover a very specific need for it.

### 2. Use a Mac companion service, not raw SSH, as the primary architecture

The Vision Pro app should talk to a small service running on the nearby MacBook Pro over the local network.

Why:

- Raw SSH sounds simple, but interactive TTY streaming, reconnection, resize handling, branch/worktree orchestration, and auth all become harder when they are pushed into the headset client.
- A companion service gives us one place to manage PTYs, worktrees, session persistence, logs, and future features.
- The headset app stays focused on layout, focus, and interaction.

Implication:

- The Mac becomes the source of truth for clusters, terminals, repo state, and process lifetime.
- The headset client becomes a native spatial UI plus networking shell.

### 3. Build the Mac companion in `TypeScript` on `Node.js` for v0

Use a small TypeScript Node service with `node-pty` and WebSockets for the first version.

Why:

- `node-pty` is mature and directly aligned with the kind of terminal/TUI streaming this app needs.
- The target CLIs (`codex`, `claude`, `opencode`) already live comfortably in a Node-heavy environment.
- This is the fastest way to get to a realistic proof of concept.
- TypeScript gives us a safer protocol boundary and better maintainability as the companion grows.

Implication:

- The repo will likely become a small monorepo:
  - `apps/vision-client`
  - `apps/mac-companion`
  - `packages/protocol` or equivalent shared schema package

### 4. Use a web terminal renderer inside native windows

For terminal/TUI windows, use an embedded `WKWebView` hosting a bundled terminal UI such as `xterm.js`, fed by the Mac companion over WebSocket.

Why:

- ANSI rendering, cursor behavior, resizing, scrollback, and TUI compatibility are already solved much better in existing terminal renderers than in a custom native text view.
- This sharply reduces the single biggest technical risk in the product.
- The app can still feel native because window management, controls, and cluster orchestration stay in SwiftUI.

Implication:

- "TUI window" and "raw terminal window" use the same rendering stack.
- The browser window can also use native `WKWebView`, but it is a separate surface type.

### 5. Treat "look and narrate" as a staged feature, not day-one infrastructure

For v0 input, support:

- hardware keyboard input
- copy/paste
- a native prompt composer with a Submit action
- system dictation into that composer if available on device

Do **not** make direct gaze-driven continuous dictation into terminal emulators the first implementation target.

Why:

- The session/workspace/terminal stack is already enough technical risk for a first product.
- Reliable gaze-targeting plus speech input into terminal UIs is a real interaction-design problem, not a small add-on.
- We should first validate that people want the room layout and cluster workflow.

### 6. One cluster equals one workspace bundle on the Mac

Each cluster should map to:

- one repo source
- one worktree path
- one branch target
- one or more terminal sessions
- optional browser metadata such as detected local dev server URLs

This is the right core data model for the whole app.

## Proposed v0 Architecture

### Vision Pro client

Responsibilities:

- pair to one Mac companion
- display a launcher window
- create/manage cluster windows
- place windows and re-open them
- render terminal surfaces and browser surfaces
- show connection state, loading state, and recoverable errors
- keep minimal local state for recent hosts and recent clusters

Likely technologies:

- `SwiftUI`
- `WindowGroup`
- `WKWebView` embedded in native views for browser and terminal surfaces
- `URLSessionWebSocketTask` or equivalent client transport

### Mac companion

Responsibilities:

- discover repos or accept repo path/URL
- create and clean up `git worktree`s
- spawn PTYs and processes
- start requested CLI sessions (`codex`, `claude`, `opencode`, raw shell)
- expose streaming terminal I/O
- store session metadata and logs
- keep sessions alive across temporary headset disconnects

Likely technologies:

- `TypeScript`
- `Node.js`
- `node-pty`
- `ws` WebSocket server
- shelling out to `git`
- JSON protocol with versioned messages

### Protocol

We should define a very small explicit protocol early.

Core message types:

- `pair`
- `create_cluster`
- `append_surface`
- `resize_surface`
- `input`
- `output`
- `list_clusters`
- `reconnect_surface`
- `close_surface`
- `destroy_cluster`
- `report_dev_server`

## Biggest Technical Risks

These are the items most likely to derail the project if we do not de-risk them early.

### Risk 1. Terminal/TUI fidelity on visionOS

This is the biggest risk in the entire app.

Failure modes:

- broken ANSI behavior
- poor resize handling
- scrollback problems
- keyboard and copy/paste issues
- CLIs behaving differently than expected

Mitigation:

- prototype `xterm.js` in an embedded `WKWebView` immediately
- test `codex`, `claude`, and a raw shell before building broader app architecture

### Risk 2. Input model for "vibe coding" on headset

The product vision depends on input being low-friction.

Failure modes:

- dictation is too awkward
- people cannot quickly target the correct window
- submit mechanics feel clumsy

Mitigation:

- first ship prompt composer + keyboard + tap submit
- test dictation as an enhancement, not as the foundational path

### Risk 3. Local-network connectivity and pairing

A local companion service is the right architecture, but local-network policy and reliability must be validated early.

Failure modes:

- privacy permission friction
- app transport security issues for local HTTP/WebSocket flows
- reconnect problems when the headset suspends or network changes

Mitigation:

- start with manual host entry on the same LAN
- add discovery only after basic pairing works
- explicitly test disconnect/reconnect and app relaunch flows

### Risk 4. Window orchestration at room scale

The product depends on multiple windows feeling spatially legible.

Failure modes:

- the app can open multiple windows but managing them becomes confusing
- restoring a cluster creates the wrong window arrangement
- too much window chrome or control UI breaks focus

Mitigation:

- keep only a few surface types in v0
- use a simple cluster launcher/control window
- avoid fancy 3D scene management until basic window layout feels good

### Risk 4A. Wrist or palm launcher may be compelling but not production-safe

The ideal one-step summon experience is:

- look at wall
- look at hand
- tap
- launcher appears
- choose repo
- terminal launches

This may be feasible with hand anchors, but it is not yet proven to be a safe foundation for a many-window productivity app.

Failure modes:

- requires a different scene model than the shared-space window app
- hand-attached UI is too unstable or too fatiguing
- gesture recognition is unreliable for repeated launches
- the launcher feels magical in demos but worse than a small utility panel in real work

Mitigation:

- treat wrist/palm UI as a separate spike, not as the default architecture
- first build a minimal prototype that only proves:
  - can we attach a tiny launcher-like object to palm or wrist
  - is it stable enough to select
  - does it feel better than a utility panel

### Wrist Launcher Spike

Question:

- Can we build a reliable hand-attached quick launcher without abandoning the shared-space terminal architecture?

Success criteria:

- the panel appears stably on palm or wrist
- the panel remains legible while the hand is in a natural resting posture
- a person can target at least two fake buttons repeatedly without frustration
- the prototype does not require reworking the main terminal architecture yet

Failure criteria:

- requires a full immersive mode to be usable
- the panel jitters, disappears, or becomes uncomfortable during repeated use
- selection is materially worse than a utility panel or ordinary launcher window

Implementation plan:

1. Add a tiny isolated spike scene in the vision client.
2. Use `RealityView` and `AnchorEntity(.hand(...))` to attach a small mock launcher to palm and/or wrist.
3. Use simple colored shapes instead of real repo UI.
4. Evaluate stability, comfort, and selection quality on device.
5. Only if it passes, plan a second spike to map those fake buttons to the real repo launcher.

Real-device test steps:

1. Open the new `Palm Spike` scene from the compact launcher.
2. Hold the left hand in a natural resting posture rather than a forced demo pose.
3. Check whether the palm panel stays visible and readable for at least 10-15 seconds.
4. Check whether the wrist marker gives enough orientation to understand where the panel is attached.
5. Decide whether this feels better than a tiny utility-panel launcher for repeated launches.

### Risk 5. Browser surface behavior for local dev servers

The browser window sounds straightforward, but local development servers introduce practical issues.

Failure modes:

- dev server URL discovery is unreliable
- auth/cookies/session state are awkward
- local HTTP access requires configuration changes

Mitigation:

- first support manually entering a URL or opening a known local dev server URL reported by the companion
- test common local stacks early (`Next.js`, `Vite`, plain docs site)

## Research Spikes We Should Do First

These are the highest-value prototypes. We should treat them as pass/fail gates before larger implementation work.

### Spike A. Multi-window Vision Pro shell

Build a minimal native visionOS app that can:

- open a launcher window
- create a new cluster
- open 2-3 associated windows
- label each window clearly
- restore cluster state after relaunch if practical

Success criteria:

- multi-window flow feels understandable in simulator
- the app structure is clearly suitable for cluster-based state

### Spike B. Embedded terminal proof of concept

Build a minimal `WKWebView` terminal surface using a mocked stream first, then a real PTY stream.

Success criteria:

- terminal text renders correctly
- resize events work
- keyboard input works
- `codex` or a shell prompt is usable enough to continue

### Spike C. Mac companion workspace manager

Build the smallest possible local service that can:

- accept a repo path
- create a worktree
- spawn a shell in that worktree
- stream PTY output
- accept input back from the client

Success criteria:

- round-trip latency feels acceptable
- session survives temporary client disconnect
- cleanup logic is explicit and reliable

### Spike D. Input and submission UX

Prototype the actual "type or dictate prompt, then submit" workflow in a headset-friendly way.

Success criteria:

- prompt submission is faster than fighting a tiny terminal text cursor
- the flow still works when multiple windows are open

### Spike E. Browser surface against a local dev server

Open a local dev server URL from the Mac companion inside a browser window on visionOS.

Success criteria:

- page loads reliably
- navigation/basic interaction work
- we understand what permissions or networking exceptions are needed

## Execution Phases

### Phase 0. Tooling and account baseline

Tasks:

- confirm Vision Pro hardware access schedule
- confirm Apple Developer account access for on-device runs and TestFlight
- confirm visionOS simulator/runtime is usable locally
- decide repo layout before generating projects

Status on this machine:

- Apple silicon: `arm64`
- Xcode installed: `26.1.1`
- visionOS SDK present locally
- Node installed: `v22.20.0`
- `pnpm` installed: `10.28.0`

### Phase 1. Repo scaffold

Deliverables:

- visionOS app scaffold
- macOS companion scaffold
- shared protocol/types package
- root scripts for local development

Acceptance criteria:

- one command starts the companion
- one command opens the visionOS project/build target

### Phase 2. Risk spikes

Deliverables:

- Spike A through E above

Acceptance criteria:

- we have evidence for or against the core architecture before committing to feature work

### Phase 3. v0 core loop

Deliverables:

- pair to a Mac
- create a cluster from repo + branch
- create a worktree
- open one TUI window by default
- append browser and raw terminal windows
- reconnect to an existing cluster

Acceptance criteria:

- a full "start coding in repo" loop works without manual terminal setup on the Mac

### Phase 4. Polish and internal beta

Deliverables:

- error handling
- reconnection states
- recent clusters
- basic observability/log export
- internal TestFlight build

Acceptance criteria:

- app is stable enough for repeated real-world sessions

## Testing Strategy

This project needs multiple test layers. Simulator alone will not be enough.

### 1. Automated tests

On the visionOS/native side:

- unit tests for cluster models, window-state models, and protocol decoding
- tests for reconnect logic and error-state transitions

On the Mac companion side:

- integration tests for PTY lifecycle
- integration tests for worktree create/delete
- tests for protocol contract and schema validation
- tests for repo/branch edge cases using temporary git repos

### 2. Simulator testing

Use simulator for fast iteration on:

- window creation and labeling
- cluster state management
- happy-path pairing UI
- browser and terminal surface embedding
- app relaunch and state restoration behavior

Simulator should be the default loop while building the shell of the product.

### 3. Real-device testing on Vision Pro

Use real hardware early and repeatedly for:

- gaze/gesture targeting
- dictation viability
- comfort of multi-window room layout
- keyboard interaction
- latency perception
- local-network behavior
- suspend/resume behavior

This should happen at least once per milestone, not only at the end.

### 4. Manual scenario checklist

These should become a standing smoke-test list.

- Pair headset app to Mac companion on same Wi-Fi.
- Create cluster from a repo and default branch.
- Create cluster from a non-default branch.
- Open default TUI surface.
- Append raw terminal surface.
- Append browser surface to a detected local dev server.
- Submit prompt via keyboard.
- Submit prompt via dictation if supported.
- Disconnect network and reconnect.
- Close and reopen the app, then reconnect to cluster.
- Verify multiple clusters can coexist without path/session confusion.

### 5. Beta distribution

Once the core loop is stable:

- use internal TestFlight for repeated device testing
- collect crash reports, logs, and UX notes after real sessions
- only then decide whether voice-first interaction deserves dedicated implementation time

## Decisions We Should Revisit After Spikes

These are intentionally not fully locked yet.

- whether the Mac companion should stay in Node long term or later move to Swift
- whether terminal sessions need `tmux` for persistence or whether the companion can own PTY lifecycle directly
- whether browser surfaces should be fully embedded or sometimes handed off to system Safari
- whether cluster window placement needs more spatial automation than default window behavior
- whether dictation should target a native composer only or eventually drive direct terminal input

## Immediate Next Steps

1. Create the repo scaffold for the visionOS client and Mac companion.
2. Build Spike A and Spike B first.
3. Prove that `codex` in a streamed terminal is usable before adding feature breadth.
4. Run the first real-device session as soon as multi-window shell plus terminal proof of concept exists.

## Current Research TODO

These are the active decision items we should work through next.

### TODO 1. Lock the v0 input UX

Research:

- verify how well native text entry and dictation work on Apple Vision Pro
- verify whether `WKWebView` terminal focus behaves well enough for keyboard-heavy workflows
- identify where native text input should exist outside the terminal surface

Preliminary decision:

- use native `SwiftUI` text input for prompt composition in v0
- rely on system dictation and system keyboard behavior rather than building custom speech-to-text
- do not assume direct dictation into terminal surfaces is good enough on day one

Open question:

- whether the best default submit flow is "type in native prompt bar, send to active terminal" or "type directly in terminal when keyboard is present"

### TODO 2. Research local-network pairing and make hard decisions

Research:

- local-network permission flow
- whether v0 should use manual host entry only or also support Bonjour discovery
- ATS requirements for local HTTP, WebSocket, and `WKWebView` content
- reconnect/error states when permission is denied or network changes

Preliminary decision:

- v0 should use manual host entry or a saved recent host, not automatic discovery
- do not trigger local-network access on app launch; wait for an explicit pairing action
- pair against the Mac’s existing Bonjour hostname on a `.local` address, for example `Sam-MacBook-Pro.local:7777`
- keep the companion API, WebSocket transport, and preview proxy under the same companion-controlled host
- add `NSLocalNetworkUsageDescription`
- add `NSAppTransportSecurity` with `NSAllowsLocalNetworking=YES`
- do not add `NSAllowsArbitraryLoadsInWebContent` in v0 unless testing proves it is unavoidable
- only add `NSBonjourServices` if we later ship Bonjour service browsing/discovery inside the app

Open question:

- whether preview surfaces can stay on a single companion port or need companion-managed preview ports for framework compatibility

### TODO 3. Research worktree lifecycle and choose the implementation strategy

Research:

- how to safely create, enumerate, and remove worktrees
- how to recover from stale or manually moved worktrees
- whether a TypeScript helper library adds enough value to justify the dependency

Preliminary decision:

- use the official `git worktree` CLI as the source of truth
- wrap it in TypeScript rather than adopting a specialized worktree abstraction for v0
- parse `git worktree list --porcelain -z` instead of scraping human-readable output
- support `add`, `list`, `remove`, `prune`, and `repair` in the companion service
- create worktrees under an app-managed root directory instead of sprinkling them around the filesystem
- default cluster creation should create a new derived branch from a selected base ref, not try to check out an already-existing branch in another worktree
- never use `--force` for normal cluster creation; treat branch collisions and stale paths as explicit errors to resolve

Open question:

- whether we should use a thin helper like `simple-git` for process ergonomics or just call `git` directly with `child_process`

### TODO 4. Keep disconnect semantics intentionally simple in v0

Research:

- what failure state messaging is needed when a session dies
- whether users understand that the Mac companion is the runtime host

Preliminary decision:

- if the headset disconnects in v0, active sessions may die
- no `tmux` persistence layer in v0
- document this limitation clearly and revisit after we validate the core loop

### TODO 5. Research browser surfaces and local dev-server routing

Research:

- how to expose local dev servers cleanly from the Mac companion
- whether `WKWebView` can load local dev URLs directly without awkward ATS exceptions
- how to normalize different dev-server ports and paths across tools like Next.js and Vite

Preliminary decision:

- the companion should detect or accept local dev-server URLs, then reverse-proxy them through the companion itself
- prefer companion-managed preview endpoints over connecting the Vision Pro app directly to arbitrary localhost framework ports
- browser surfaces should be "preview surfaces" managed by the companion, not raw free-form local port connections in v0
- preview proxying must support WebSocket upgrade because Vite-style HMR expects reverse proxies to handle WebSocket correctly
- avoid path-prefix proxying as the default assumption for arbitrary repos; many frameworks assume they are hosted at `/`

Open question:

- whether preview surfaces can share the main companion port or should use companion-owned preview ports on the same `.local` host

## Research Outcomes

### Local-network pairing

Decision:

- v0 uses manual pairing to a Mac companion hostname like `<computer-name>.local:7777`.
- The app requests local-network access only when the person initiates pairing.
- Companion traffic should stay on one companion-controlled `.local` host to keep ATS handling narrow and predictable.

Why:

- Apple’s ATS reference explicitly provides `NSAllowsLocalNetworking` for local resources on unqualified and `.local` domains, which is a cleaner fit than broad arbitrary-load exceptions.
- A manual pairing flow avoids the extra complexity of Bonjour browsing and its plist declarations in v0.

Implementation note:

- The native app should talk to the companion with normal HTTP/WebSocket APIs on the `.local` host.
- We should avoid IP-literal pairing as the primary product path because ATS exception handling is less clean there.

### Worktree lifecycle

Decision:

- The companion owns worktree lifecycle entirely through the official `git worktree` CLI.
- Cluster creation should create a fresh branch off a chosen base ref using `git worktree add -b <new-branch> <path> <base-ref>`.
- The companion should maintain its own metadata about clusters and sessions, but Git remains the source of truth for worktree state.

Why:

- Official Git behavior already covers the hard edge cases we care about: refusing branch collisions, enumerating worktrees via porcelain output, pruning stale entries, and repairing moved worktrees.
- Existing tools in this space typically add metadata and hooks around worktrees rather than replacing Git’s own model.

Implementation note:

- We should parse `git worktree list --porcelain -z`.
- We should expose explicit admin actions in the companion for cleanup and repair.
- We should not use `--force` except for deliberate maintenance flows.

### Preview surfaces

Decision:

- The companion should own preview routing and expose companion-managed preview endpoints to the headset.
- Do not connect the AVP app directly to random framework ports like `3000` or `5173`.
- Do not assume path-prefix proxying will work for arbitrary repos without extra configuration.

Why:

- Vite documents that reverse proxies must support WebSocket for HMR.
- Next.js and Vite both support sub-path hosting, but those approaches generally require app-specific configuration and should not be assumed for arbitrary repos.

Implementation note:

- The safest v0 design is likely one `.local` host with a fixed main API/WebSocket port plus companion-owned preview port(s) as needed.
- A good v0 shape is a fixed companion control port such as `7777`, with preview proxies allocated from a small managed range such as `7801-7899`.
- Validate this against at least one Next.js app and one Vite app before locking the final proxy shape.

## v0 Implementation Contract

This is the concrete shape I recommend we build first.

### Core principle

Keep the system boring:

- one native `SwiftUI` visionOS app
- one TypeScript companion service on the Mac
- one fixed control origin on the Mac
- one WebSocket for control events plus terminal streaming
- explicit worktree ownership by the companion

Avoid optional infrastructure in v0:

- no Bonjour discovery
- no `tmux`
- no cloud relay
- no cross-network support
- no arbitrary external browser inside the app

### Companion network shape

Companion origin:

- `http://<computer-name>.local:7777`

Responsibilities on port `7777`:

- health check
- pairing handshake
- cluster/session control APIs
- WebSocket upgrade for realtime events and PTY streams

Preview ports:

- allocate from a managed range such as `7801-7899`
- all preview ports stay on the same `.local` hostname
- the companion owns port assignment and cleanup

Why this shape:

- the control plane stays fixed and easy to reason about
- preview routing can remain flexible without polluting the main protocol
- the AVP app only needs to learn one hostname per paired Mac

### Minimal companion API

HTTP:

- `GET /health`
  - returns companion version, hostname, and readiness
- `GET /repos`
  - lists known/selectable local repos if we choose to support browsing
- `GET /clusters`
  - returns active and recent clusters
- `POST /clusters`
  - creates a cluster from repo + base ref + new branch + default surfaces
- `POST /clusters/:clusterId/surfaces`
  - appends a new surface such as `tui`, `terminal`, or `preview`
- `POST /clusters/:clusterId/reveal-preview`
  - requests or registers a preview URL from the companion
- `DELETE /clusters/:clusterId`
  - destroys cluster metadata and optionally removes the worktree

WebSocket:

- `GET /ws`
  - single socket for:
    - session events
    - PTY output
    - PTY input
    - resize messages
    - connection state
    - preview state updates

### Minimal realtime protocol

We should keep the protocol small and typed.

Client to companion:

- `hello`
- `subscribe_cluster`
- `create_surface`
- `terminal_input`
- `terminal_resize`
- `request_preview`
- `close_surface`

Companion to client:

- `hello_ack`
- `cluster_snapshot`
- `surface_created`
- `terminal_output`
- `surface_closed`
- `preview_ready`
- `error`

Protocol constraints:

- every message includes a `type`
- IDs are generated by the companion
- terminal output is streamed as raw data payloads tied to a `surfaceId`
- cluster snapshots are authoritative and can fully rebuild client state after reconnect

### Worktree ownership model

Companion-managed root:

- `~/Library/Application Support/SlopZooka/worktrees/`

Recommended layout:

- `~/Library/Application Support/SlopZooka/worktrees/<repo-slug>/<cluster-id>-<branch-slug>/`

Rules:

- every cluster gets a generated `clusterId`
- every cluster creates a fresh derived branch
- every cluster knows:
  - source repo path
  - base ref
  - generated branch name
  - worktree path
  - active surfaces
  - preview assignments

Recommended branch naming:

- `slz/<repo-slug>/<short-cluster-id>/<task-slug>`

Why:

- it avoids collisions with the user’s normal branches
- it makes ownership obvious
- it gives us a stable naming convention for cleanup

### Surface model

Surface types in v0:

- `tui`
- `terminal`
- `preview`

Rules:

- `tui` and `terminal` are both PTY-backed and rendered with the same `WKWebView` + `xterm.js` stack
- `preview` is a native `WKWebView` pointed at a companion-managed preview URL
- the cluster launcher/control window is native SwiftUI, not a terminal surface

### Input model

Default v0 UX:

- native cluster control window with prompt composer
- active surface selection is explicit in the app state
- "Send" writes the composed prompt into the selected PTY
- direct keyboard interaction in the terminal surface still works when focus is there

Why:

- this lets us benefit from native text input and system dictation
- it reduces dependence on `WKWebView` focus for the primary prompt flow

## Early Derisk Test Plan

The first implementation milestones should exist to prove reliability, not feature breadth.

### Stage 1. Mac-only PTY harness

Goal:

- prove the companion can create PTYs, stream bytes cleanly, resize correctly, and clean up reliably before Vision Pro is involved

Build:

- minimal TypeScript companion
- one local test page or CLI subscriber
- one PTY session running `/bin/zsh`

Must-pass checks:

- spawn PTY and receive prompt
- send input and receive echoed output
- resize PTY and confirm terminal applications respond correctly
- close PTY and confirm child process exits
- run multiple PTYs simultaneously without stream mixups

Suggested commands:

- `pwd`
- `ls`
- `printf` with ANSI colors
- `top` or another interactive program only if it is stable enough for testing
- `codex --help` and other non-destructive CLI commands

### Stage 2. Mac-only browser terminal renderer

Goal:

- prove `xterm.js` rendering is correct against real PTY data before embedding in AVP

Build:

- same companion
- local browser client using the same WebSocket protocol the AVP app will use

Must-pass checks:

- ANSI colors and cursor movement render correctly
- long output scrollback behaves correctly
- copy/paste works
- resize events are reflected in the PTY
- no obvious corruption under sustained output

### Stage 3. visionOS simulator network shell

Goal:

- prove the native app can pair, connect, host `WKWebView`, and stream a PTY in the simulator

Build:

- minimal SwiftUI app with:
  - manual hostname entry
  - health check button
  - connect button
  - one terminal window

Must-pass checks:

- manual `.local` pairing succeeds
- `GET /health` works
- WebSocket opens and stays stable
- terminal output appears in the embedded renderer
- input from the simulator keyboard reaches the PTY

### Stage 4. Real-device Vision Pro smoke test

Goal:

- validate the same stack on actual hardware before adding more product logic

Must-pass checks:

- pair to the Mac on the same Wi-Fi
- open a terminal window and receive a shell prompt
- type simple commands from a hardware keyboard
- use the native prompt composer and send text to the PTY
- disconnect and verify failure is understandable and clean
- reconnect and create a fresh session successfully

### Stage 5. Worktree-backed cluster smoke test

Goal:

- prove the first real cluster lifecycle from repo selection through worktree creation

Must-pass checks:

- create a cluster from a repo and base branch
- verify worktree path is created under the app-managed root
- verify generated branch name matches convention
- launch default TUI surface in that worktree
- destroy cluster and verify cleanup behavior matches the documented policy

## Reliability Gates

These are the standards the implementation must meet before we call the early stack validated.

### Gate A. PTY correctness

- terminal bytes are not dropped or reordered in normal use
- resize events reach the PTY reliably
- each surface maps to exactly one PTY session
- PTY cleanup does not leave obvious orphan processes behind

### Gate B. Network cleanliness

- pairing works from a `.local` hostname without manual IP entry
- the app surfaces local-network permission failures clearly
- the control socket reconnect path is predictable even if v0 sessions do not persist
- preview ports are allocated and released cleanly

### Gate C. UX cleanliness

- the user can always tell which cluster and surface they are interacting with
- prompt sending via native composer is unambiguous
- the app fails visibly and recoverably instead of silently hanging

## Observability for v0

We need enough logging to debug early failures quickly.

Companion logs:

- cluster create/destroy
- worktree command invocations
- PTY spawn/exit
- WebSocket connect/disconnect
- preview port allocation/release

Client logs:

- pairing attempts
- health-check results
- WebSocket lifecycle
- surface creation/failure
- prompt submission events

Debugging rule:

- every cluster and every surface gets a stable ID that appears in both companion and client logs

## Research Notes

Official Apple guidance that informed this plan:

- Apple says visionOS apps can mix windows, volumes, and spaces, and recommends starting with a window and adding immersion as needed: https://developer.apple.com/visionos/get-started/
- Apple states that new visionOS projects in Xcode use `SwiftUI`: https://developer.apple.com/visionos/get-started/
- Apple highlights App Store Connect and TestFlight as the path to test and deploy visionOS apps: https://developer.apple.com/visionos/get-started/
- Apple’s current Xcode system requirements page shows modern visionOS SDK support in current Xcode releases: https://developer.apple.com/xcode/system-requirements/
- Apple’s visionOS updates continue to deepen the `SwiftUI` + `RealityKit` development model, which supports keeping our v0 native and window-first: https://developer.apple.com/visionos/whats-new/

Local SDK verification performed on this machine:

- Xcode `26.1.1` is installed.
- The local Xcode SDKs include `visionOS 26.1` and `Simulator - visionOS 26.1`.
- The installed `xros` SDK includes `WebKit.framework` and `WKWebView`, which supports the proposed embedded browser/terminal strategy.

## Near-Term Todo

Current execution slice:

- [x] Make the quick launcher scroll cleanly instead of vertically compressing repo rows.
- [x] Add clearer launch/error feedback so failures are visible in the launcher.
- [x] Add safe workspace lifecycle actions in the companion and client.
- [x] Add a missing-workspace cleanup action instead of leaving stale entries around forever.
- [x] Return cleaner workspace HTTP error codes for not-found and conflict cases.
- [ ] Validate the refined launcher flow on device and simulator with a few real workspaces.
