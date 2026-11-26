# Terminal Controls Lab

Use this standalone visionOS app for fast headset experiments with terminal
chrome, menus, and dictation. Open `TerminalLab.xcodeproj`, select the
`TerminalLab` scheme, and run on the simulator or a development Vision Pro.
The separate bundle ID lets the lab and SlopZooka coexist. See the
[run guide](README.md) for signing, launch arguments, and scenario controls.

Start in the lab when experimenting with gaze targets, placement, or
transitions. Change a fixture or view, rebuild just the lab, and use its separate
controls window to compare states on the headset. The fixtures run without a
companion, PTY, or live speech. Keep real windows, networking, and process
lifecycle in the production app.

The lab is a workshop and may lag behind production. Check the current
production view before judging parity. Link existing UI components where their
dependencies fit the lab and keep the fixture code small. Once an experiment is
approved, port the interaction through the production owners and verify the
production entry point independently. For terminal windows, those owners are
`TerminalWindowView`, `TerminalVoiceOverlay`, and `WindowGateway`.

Run XcodeGen with `xcodegen generate --spec labs/terminal-controls/project.yml`
after adding or moving project files. Leave the lab out of production targets.
