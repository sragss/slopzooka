Goal: Apple Vision Pro app for vibe coding.


The issue with the Vision Pro and computer is that you only get a single monitor. And note you can make this monitor as big as you want, and it feels like an 80 inch screen. But I'm a big spaces user. I like having different monitors. One of the things I like about it are that humans are good at geo-spatial association. "Space X is good for A, Space Y is good for B, etc". When you go to that space, you're ready to focus on the relevant context. When you put on your soccer cleats, you're ready for games, when you sit in your lawn chair, you're ready to relax.

The vision pro has the opportunity to go beyond spaces. I'm a developer, and so coding is number 1 for me. The current state of the art for coding is TUI programs like Claude Code, Codex, OpenCode and Gemini CLI. This is actually remarkably convinient for what we want to do.

Enter an open space. Spawn new windows around the room and pin them up. Each window is a new programming window, looking at a window and narrating allows you to type into it. Then prompts can be submitted with a single tap.

So the core UX.
- Launch app in open space
- One gesture to launch new window
        1. TUI (Codex, ClaudeCode, OpenCode)
        2. Browser
        3. Raw Terminal
- When we launch a fresh cluster it starts with the TUI, then Browser and Raw terminal can be appended. These point at same directory / workspace
- So fresh launch requests what Github repo you'd like to target and makes a new worktree there. Default is remote default (remote head of master / main). But other branches can be selected too. Happy path does that very quickly



Architecture:
- Rely on same-network macbook pro to actually run all the terminals. Connect over SSH or something similar using a node pty / tty stream. The actual app should be as dumb as possible and should just basically be layout stuff
- I'm not sure if we need to run a server or if we can just open SSH or something like that. Would like this to be as simple and reliable as possible.
- Each new cluster makes a new workspace



Supported TUI / CLI frameworks:
- Claude Code
- Codex
- OpenCode


Window types
- Claude / Codex / OpenCode TUI Window
- Browser window (for reviewing server)
- Terminal window



Future features, out of scope for v0
- Terminal window auto suggestions actions based on context. Because TUIS are annoying we should likely just feed a recent screenshot into claude with a good prompt (pnpm i, pnpm build, pnpm dev, open ., etc)
- Same-room mutliplayer
- Cross-country (not same room) multiplayer
- Cloud hosting for Claude Instances
- Auto forking of chats
