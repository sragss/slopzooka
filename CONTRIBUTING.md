# Development

[Back to README](README.md) · [Architecture](docs/architecture.md) · [Agent guidance](AGENTS.md)

## Prerequisites

Use macOS, Node.js 22+, pnpm 10.28.0 (pinned in `package.json`), and Xcode 26.3 (Swift 6.2) with the visionOS SDK. Native checks require Xcode command-line tools; HTTPS fixtures require `openssl`. Install the project tools you intend to run, and authenticate GitHub CLI with `gh auth login` for repository browsing, or set `GITHUB_TOKEN` / `GH_TOKEN`.

```sh
pnpm install
pnpm setup:swiftlint
```

`setup:swiftlint` downloads the pinned macOS SwiftLint release into the ignored
`.build/swiftlint` directory and verifies its SHA-256 checksum. Run it again after
updating the version in `.swiftlint.yml` and the archive checksum in
`scripts/install-swiftlint.mjs`. TypeScript lint dependencies are pinned in
`package.json` and `pnpm-lock.yaml`.

## Run the companion

For companion development, run `pnpm dev:companion` instead of the menu-bar app. This prints the pairing code in Terminal. Open `http://localhost:7777/dashboard` for the desktop dashboard and pair with the same code.

`pnpm dev:companion` also builds the small native transport helper. Set `SLOPZOOKA_DIRECT=0` to omit peer advertising for an isolated fixture or when working only on Local Network behavior. `pnpm --filter @slz/mac-companion build:transport` rebuilds the helper directly. Direct requires macOS 15+; ordinary Local Network remains available on older supported Macs.

`pnpm dev:companion` does **not** restart on source changes. Use `pnpm --filter @slz/mac-companion dev:watch` to restart the HTTP companion on changes while the same session service keeps its terminals running. Terminal-engine changes require an explicit session-service restart, which ends its sessions. Rebuild the Mac app after changing its bundled host or native code.

Keep development separate from your installed app. For example, use a dedicated home and port, and disable the shared dashboard alias:

```sh
SLOPZOOKA_HOME="$HOME/.slopzooka-dev" \
  SLOPZOOKA_PORT=7778 \
  SLOPZOOKA_PORTLESS=0 \
  pnpm dev:companion
```

Open `http://localhost:7778/dashboard` for this instance. In the headset, use manual address entry with your Mac's LAN address and port `7778`.

There is one session service per canonical `SLOPZOOKA_HOME`, independent of the HTTP port. Run only one HTTP companion per home. `/health` identifies development versus packaged code. Set `SLOPZOOKA_BUILD_DIR` to stage an independent Mac app bundle.

## Reload browser content

For terminal web UI development, keep your development companion running and run
`pnpm --filter @slz/mac-companion dev:web` in another terminal. The watcher rebuilds
browser assets without restarting the host or its PTYs. Use **Reload Content** in
a terminal's actions menu, or the launcher's reload button for all visible windows.
This reloads content inside the same native scenes. Preview reload also refreshes
its gateway connection while keeping the WebView. Swift changes still require a
native build; this workflow does not inject Swift code into a running app. The
packaged Mac app serves its bundled assets, so use the development companion for
this workflow.

## Make changes

Use the [architecture map](docs/architecture.md) to find the owner of the behavior you are changing. Keep lifecycle logic in that owner. In particular, preserve the [window invariants](AGENTS.md#window-architecture) and keep the TypeScript and Swift schemas compatible.

Edit browser sources in `apps/mac-companion/src`, then run `pnpm build:harness`. The browser assets under `apps/mac-companion/public` are checked in; commit regenerated output with source changes. `build:harness` builds the dashboard, terminal renderer, and desktop bug-report page.

Run `pnpm format` for TypeScript formatting. Add regression coverage for behavior changes, especially reconnects, cancellation, persistence, and process lifetime. Document user-facing changes in the relevant guide; keep the README focused on getting started.

Prefer tests through real HTTP, files, PTYs, and WebKit. Substitute external
services, hardware, or scheduling only where needed to exercise failures and
races. Avoid homemade DOM replicas and repeated assertions already covered by
an integration check. Keep regressions for ownership, cancellation, and recovery.

Run `pnpm lint` for both languages, or `pnpm lint:ts` / `pnpm lint:swift`
individually. CI runs the same checks and fails on warnings. ESLint uses the
recommended JavaScript and TypeScript correctness rules, with additional promise,
`await`, and exhaustive-switch checks on companion and shared protocol sources.
Tests use the recommended rules without typed linting and allow `any` for test
doubles; unused arguments and caught errors can be prefixed with `_`. SwiftLint
uses the explicit correctness-rule list in `.swiftlint.yml` for both native apps
and their shared runtime, including image accessibility and private SwiftUI state. A custom rule keeps the
headset's native window actions in `WindowScene.swift`; `lint:swift` also checks
that rule against allowed and rejected examples. Both production Swift builds
enable complete concurrency checking and treat Swift compiler warnings as errors.
Generated browser assets are excluded. Keep formatting with Prettier, and document
intentional rule exceptions at the relevant line rather than disabling checks
across a file.

### Logging

Use a scoped logger at the existing behavior owner. Node processes create one
runtime with `createDiagnostics`; components receive `diagnostics.logger("component")`.
Only process bootstrap and diagnostics routes access `diagnostics.store`.
Browser components use `browserLog("component")`; native components use
`AppLog("component")`. Bind stable IDs with `child`, use named events and structured
flat scalar metadata, and pass `Error` values directly. Use `logError` for unknown
catch values; rich errors retain name, message, stack, code, and bounded causes.
Node request boundaries establish action/request correlation with `logContext.run`;
scoped loggers read that context. Native `AppLog.operation` records duration and
outcome and carries its action ID through native requests. Never log raw
input, transcripts, credentials, request bodies, or environment dumps. Summarize
high-volume traffic rather than adding events to every output/ack/input frame.

The diagnostic envelope and native bridge fixture live in `packages/protocol`.
`pnpm test` exercises storage, intake, redaction, clock observations, bootstrap failures, and incident export;
`pnpm test:vision-state` also checks native buffering and authenticated retries.
Both native apps compile the UI-independent runtime and file sink in `apps/shared`.
Only the debug panel observes `NativeDiagnostics.recentEntries`. Outbox routing,
clock calibration, and delivery do not publish UI updates. Both Node and native
writers begin fresh segments after startup or write failure, reserve a whole
segment’s capacity, and prune only when opening a segment. The native file actor
serializes disk work off the main actor. Logs always belong to `SLOPZOOKA_HOME/logs`.

The headset bug reporter is a native voice composer using the shared microphone
controller. Pauses preserve its draft; review and public submission are separate
explicit actions. Keep the public projection in `bug-report-draft.ts` explicit:
user text, incident time, report ID, and validated build/runtime fingerprints.
Never serialize a capture wholesale into an issue URL or body. Paired native
requests prepare a bounded, expiring draft; submission references exactly that
draft and caches the result to avoid retrying uncertain GitHub writes. The native
flow keeps rejected requests separate from uncertain writes: expiry and auth
rejections require fresh review; cancellation/timeouts cannot rearm submission.
Account verification and issue creation share one credential snapshot. GitHub
credentials stay on the Mac. The desktop browser flow uses GitHub’s composer;
`bug-report.ts` saves/links the authenticated local snapshot. Neither flow uploads
logs. Test with fake GitHub writers; never create real issues in regression checks.

## Verify

From the repository root:

```sh
pnpm lint
pnpm typecheck
pnpm test
pnpm test:vision-state
pnpm test:terminal-keyboard
pnpm format:check
pnpm build:harness
git diff --exit-code -- apps/mac-companion/public
xcodebuild -project apps/vision-client/SlopZooka/SlopZooka.xcodeproj \
  -scheme SlopZooka -sdk xrsimulator -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/slz-derived CODE_SIGNING_ALLOWED=NO build
```

| Check                         | Coverage                                                                                                                                                                                      |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pnpm lint`                   | TypeScript sources and tests, shared protocol sources, and both native apps; correctness checks without formatting or size limits                                                               |
| `pnpm test`                   | Companion integration tests with temporary homes, real PTYs, and isolated HTTP/HTTPS/WebSocket fixtures; authentication, replay, process cleanup, workspace mutations, frontend lifecycle, and native HTTP/WebSocket/TLS transport, EOF cleanup, and two real WebKit terminals reconnecting to isolated PTYs |
| `pnpm test:vision-state`      | Native launcher, window gateway/persistence, voice (including utterance boundaries and task rotation), immersion, and zoom state checks on macOS                                              |
| `pnpm test:terminal-keyboard` | Real WebKit input, renderer zoom/resize behavior, and preview back/forward history                                                                                                                                           |
| `pnpm format:check`           | TypeScript sources and companion tests                                                                                                                                                        |
| `pnpm build:harness`          | Regenerate browser assets; the subsequent diff check detects uncommitted output                                                                                                               |
| visionOS simulator build      | Compile the full headset app                                                                                                                                                                  |

Tests do not modify your live Portless registry, workspaces, or GitHub repositories. Closing repository creation cancels waiting; it cannot undo a repository already created on GitHub.

For Mac app packaging or supervision changes, also run:

```sh
pnpm build:mac-app
pnpm test:mac-app
```

CI opts into ad-hoc signing with `SLOPZOOKA_SIGN_IDENTITY=-`. Local builds normally use a certificate; see [Mac signing](docs/mac-companion.md#signing-and-distribution). The packaged-app checks use an isolated home and port; they do not enable login startup or modify your live companion. They verify the signed bundle, assets, PTY runtime, supervision, session survival across UI/HTTP restarts, and startup timeout handling.

### Physical Vision Pro checks

Simulator compilation and macOS state tests do not establish device behavior. Before relying on a headset release, verify:

- Pair; open an agent and a shell in one workspace; close/reopen windows; sleep/wake during output.
- Type through Mac Virtual Display immediately after opening, switching, and recovering terminals. Check capitals/Caps Lock, shifted punctuation, Control-C, Shift-Tab, modified arrows, and delivered function/navigation keys. Request and dismiss the floating keyboard, then repeat.
- With both a directly connected keyboard and Mac Virtual Display keyboard sharing, use Option+Up (Alt+Up) in Codex; check modified arrows and key repeat with the floating keyboard requested and dismissed.
- Rebuild over the existing installation; recover without the launcher; check system close, room lock, and placement. visionOS owns placement, so reopening content does not guarantee its previous position.
- Hold the terminal microphone across pauses and the 50-second recognition handoff (including any clipped words); release and check the three-second border fill, × cancellation, and delivery click/pulse. Try a quick tap and release during a permission prompt. Switch terminals; deny permission; interrupt the connection during countdown/send; background/sleep and resume; stop capture from Settings in normal and immersive modes.
- Open Next.js/Vite apps with HMR, authentication, and cross-service requests. Validate LAN certificate trust and framework origin policies.
- Put two terminals on opposite sides of the room; emit `printf '\a'` in each. Check that each chime comes from its own window, its orange border clears when selected, and reconnect/reload does not repeat the sound. Repeat while dictating.
- In the terminal’s **…** popover, gaze at each row and zoom button, then pinch near its center and edges. Check that highlights stay on one rounded target and neighboring actions do not fire. Open **Report a Bug**, verify voice starts after the popover closes, and cancel without publishing. Repeat in immersive mode and with a disconnected terminal; a terminal on another accepted Mac must capture from its own Mac.
- Check physical wrist tracking and comfort in immersive mode.

### Voice Playground

The standalone [Voice Playground](docs/voice-playground.md) exercises hold-to-talk,
the three-second cancel countdown, and delivery feedback without pairing. Its
Xcode target references the production voice sources directly and routes delivery
to a local message list, so UI refinements stay identical in both apps.

```sh
pnpm test:voice-demo
xcodebuild -project apps/voice-ux-demo/VoicePlayground.xcodeproj \
  -scheme VoicePlayground -sdk xrsimulator -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/slz-voice-playground CODE_SIGNING_ALLOWED=NO build
```

To install on a development headset, open the demo project in Xcode, select your
signing team and headset, and run the VoicePlayground scheme. Its bundle ID is
separate from SlopZooka. Grant the demo microphone and speech permissions before
trying the first hold. `pnpm lint` includes the demo's Swift sources; the state
checks cover final transcript corrections, empty holds, countdown cancellation,
stale callbacks, and the full three-second delay. Sound, gesture feel, and comfort
still need the headset pass.

### Native window preview development

The experimental capture provider is built by `pnpm dev:companion` and Mac app
packaging. Enable it with `SLOPZOOKA_WINDOW_PREVIEWS=1` on an isolated companion
home/port. Do not run a second companion against your live home. A development
shell's Screen Recording grant does not establish the final signed app's grant.

`pnpm test:vision-state` includes bounded media protocol and real loopback receiver
checks. `pnpm test:native-video` additionally exercises hardware H.264 encoding and
real VideoToolbox decoding across portrait/landscape changes; run it on a Mac with
an available hardware encoder. These checks do not capture a desktop, open Mac
permission prompts, or install anything on a headset. See the
[native preview plan](.plans/2026-11-10-native-preview-implementation.md) for the
separate signed-app/device gate. Packaging and simulator builds alone cannot
establish capture permission attribution, perceived latency, or scene sizing.
