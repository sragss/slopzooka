# SlopZooka

Spatial coding for Apple Vision Pro. Launch terminal windows into the space around you, each running Claude Code, Codex, or OpenCode against a real repo on your Mac.

## How it works

Put on Vision Pro. Pick a GitHub repo. Terminals appear as floating windows you can pin anywhere in the room. Dictate prompts with your voice, submit with a tap. Your Mac does the actual compute — the headset is just glass.

**Architecture:** Two pieces talk over your local network.

- **Vision Client** — visionOS app. Renders terminal windows, browser previews, and the launcher UI. Discovers the companion via Bonjour. Streams terminal I/O over WebSocket.
- **Mac Companion** — Node server running on your MacBook. Manages `node-pty` sessions, git worktrees, and preview proxying. Serves the xterm.js frontend that the Vision Client loads in `WKWebView`.

```
┌─────────────────────┐         WebSocket / HTTP         ┌──────────────────────┐
│   Apple Vision Pro  │  ◄──────────────────────────────► │   MacBook (companion)│
│                     │        local network              │                      │
│  SwiftUI launcher   │                                   │  Express + node-pty  │
│  xterm.js terminals │                                   │  git worktrees       │
│  WKWebView previews │                                   │  preview proxy       │
└─────────────────────┘                                   └──────────────────────┘
```

## Project structure

```
apps/
  vision-client/    SwiftUI visionOS app (Xcode project)
  mac-companion/    Node.js companion server
packages/
  protocol/         Shared message types (TypeScript)
```

## Setup

Prerequisites: macOS, Node.js 22+, pnpm, Xcode with visionOS SDK.

```bash
pnpm install

# Start the companion server on your Mac
pnpm dev:companion

# Open apps/vision-client/SlopZooka in Xcode, build & run on Vision Pro or simulator
```

The Vision Pro app discovers the companion automatically via Bonjour. If auto-discovery fails, enter your Mac's hostname or IP manually in the launcher.

## Window types

- **TUI Terminal** — Claude Code, Codex, or OpenCode running in a full xterm.js session
- **Browser Preview** — proxied view of a local dev server (e.g. `localhost:3000`)
- **Raw Terminal** — plain shell for running commands

Each workspace creates a git worktree, so multiple coding sessions don't interfere with each other.

## Status

Early prototype. Works on-device for local development. See `PLAN.md` for the full design and future direction.
