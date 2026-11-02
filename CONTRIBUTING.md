# Development

[Back to README](README.md) · [Architecture](docs/architecture.md) · [Agent guidance](AGENTS.md)

## Prerequisites

Use macOS, Node.js 22+, pnpm 10.28.0 (pinned in `package.json`), and Xcode with the visionOS SDK. Native checks require Xcode command-line tools; HTTPS fixtures require `openssl`. Install the project tools you intend to run, and authenticate GitHub CLI with `gh auth login` for repository browsing, or set `GITHUB_TOKEN` / `GH_TOKEN`.

```sh
pnpm install
```

## Run the companion

For companion development, run `pnpm dev:companion` instead of the menu-bar app. This prints the pairing code in Terminal. Open `http://localhost:7777/dashboard` for the desktop dashboard and pair with the same code.

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

Edit browser sources in `apps/mac-companion/src`, then run `pnpm build:harness`. The browser assets under `apps/mac-companion/public` are checked in; commit regenerated output with source changes. `build:harness` builds both the dashboard and terminal renderer.

Run `pnpm format` for TypeScript formatting. Add regression coverage for behavior changes, especially reconnects, cancellation, persistence, and process lifetime. Document user-facing changes in the relevant guide; keep the README focused on getting started.

## Verify

From the repository root:

```sh
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
| `pnpm test`                   | Companion integration tests with temporary homes, real PTYs, and isolated HTTP/HTTPS/WebSocket fixtures; authentication, replay, process cleanup, workspace mutations, and frontend lifecycle |
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
- Type through Mac Virtual Display immediately after opening, switching, and recovering terminals. Request and dismiss the floating keyboard, then repeat.
- Rebuild over the existing installation; recover without the launcher; check system close, room lock, and placement. visionOS owns placement, so reopening content does not guarantee its previous position.
- Dictate across pauses, repeated sends, and the 50-second recognition handoff (including any clipped words); switch terminals; deny permission; interrupt the connection during send; background/sleep and resume; stop capture from Settings in normal and immersive modes.
- Open Next.js/Vite apps with HMR, authentication, and cross-service requests. Validate LAN certificate trust and framework origin policies.
- Put two terminals on opposite sides of the room; emit `printf '\a'` in each. Check that each chime comes from its own window, its orange border clears when selected, and reconnect/reload does not repeat the sound. Repeat while dictating.
- Check physical wrist tracking and comfort in immersive mode.
