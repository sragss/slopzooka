# SlopZooka

Spatial coding for Apple Vision Pro. Put agent terminals, shells, and web previews around your room, with your Mac running the processes behind them.

Each workspace is a Git worktree. Open Codex, Claude Code, OpenCode, or a shell, then bring its frontend into a nearby window. Local web servers appear automatically; you can also use an existing Portless registry or save a URL.

## Get started

You need a Mac and Apple Vision Pro on the same trusted local network. Build from source with Node.js 22+, pnpm 10.28.0, and Xcode with visionOS support. The Mac app build requires an Apple Development or Developer ID signing identity; see [signing options](docs/mac-companion.md#signing-and-distribution) for local test builds.

```sh
pnpm install
pnpm build:mac-app
```

1. Move `build/mac-app/SlopZooka.app` to Applications and open it. It runs in the menu bar.
2. Install your preferred agent CLI on the Mac. For GitHub repository browsing, sign in with `gh auth login` or supply `GITHUB_TOKEN` / `GH_TOKEN`.
3. Open `apps/vision-client/SlopZooka/SlopZooka.xcodeproj` in Xcode and run it on Vision Pro.
4. Select your Mac in the headset and enter the pairing code shown on the Mac.
5. Choose a repository and tool in **Projects** to create a workspace, or reopen a session from **Terminals**. Start your project's web server normally and find it under **Frontends**.

Use **Open Dashboard** in the Mac menu to manage sessions and frontends from your browser. The packaged Mac app includes Node and its runtime dependencies; your project tools still need to be installed separately.

## Working in SlopZooka

- **Spatial windows:** Open multiple terminals and previews per workspace. Window recovery remembers which content to reopen; visionOS manages physical placement.
- **Persistent terminals:** Closing a window, disconnecting, or restarting the menu app leaves terminal processes running. **End Session** stops them. Session-service restarts and Mac reboots end sessions.
- **Keyboard and voice:** Type with a connected keyboard, tap a terminal to focus input, or dictate into a selected terminal. Persistent voice input keeps a draft across pauses and lets you send repeatedly.
- **Web previews:** Discover local HTTP servers, use Portless routes, or add HTTPS and deployed URLs. Local previews use an authenticated gateway so loopback servers stay reachable from the headset.
- **Optional immersion:** A wrist menu opens the launcher and recent terminals while keeping your room visible.

The control connection uses HTTP on your local network. Pairing controls access but does not encrypt that transport; keep the companion port off the public internet. See [authentication and network access](docs/mac-companion.md#authentication-and-network-access).

## Documentation

| Guide                                  | Contents                                                                      |
| -------------------------------------- | ----------------------------------------------------------------------------- |
| [Mac companion](docs/mac-companion.md) | Installation, signing, session controls, dashboard, and environment variables |
| [Vision Pro](docs/vision-pro.md)       | Pairing, keyboard, zoom, dictation, immersion, and window recovery            |
| [Frontends](docs/frontends.md)         | Discovery, workspace configuration, Portless, and HTTPS previews              |
| [Development](CONTRIBUTING.md)         | Isolated setup, live reload, checks, and device validation                    |
| [Architecture](docs/architecture.md)   | Source map, process ownership, terminal transport, and window boundaries      |
| [Agent guidance](AGENTS.md)            | Repository conventions and window lifecycle invariants                        |

Contributions should keep process ownership on the Mac and route native window lifecycle through the existing gateway. Start with [CONTRIBUTING.md](CONTRIBUTING.md).
