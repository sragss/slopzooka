# Connection Lab iteration log

Add dated entries as the lab evolves. Include the affected flow and any
production behavior that was refreshed or intentionally changed.

## 2026-11-26

- Built a standalone visionOS app with 45 presets for discovery, pairing, Local
  Network, Direct, settings, and permissions. Added a separate Controls window
  for staging results and stepping pending requests.
- Tried a visionOS Settings–inspired split view, then moved first-run setup
  into a compact Mac picker. Kept workspace navigation visible during reconnect.
- Put connection status behind the Mac name, with a dedicated picker for switching
  Macs and a separate connection-method page with a back arrow.
- Added cancellation for pending connection and pairing checks. Moved the
  labeled Cancel button into the status row.
- Added a two-second simulated connection for the walkthrough so reviewers can
  reach the launcher directly. Kept the code-entry flow available in the
  pairing presets.
- Split Repos, Worktrees, and Threads into sidebar destinations. Put Frontends
  below a divider and opened terminals from individual entries. Added sample
  repositories, worktrees, recent Codex threads, frontends, and writable
  simulated terminals. Grouped worktrees by repository.
- Aligned gaze targets to the visible row outlines on the Mac picker and
  workspace catalogs. Made the option bars and Troubleshooting full-row
  targets with matching padding.
- Removed the remaining production source references. Archived the prototype
  as a self-contained project with an editing guide and fixture checks.
- Replaced the Troubleshooting disclosure with visible address and log rows
  and a full-width reload action in the connection sheet.
- Moved retry into the interrupted connection status row as a circular arrow.
- Distinguished an interrupted connection from an active reconnect. Kept
  worktree rows readable and labeled their session badges as last known.
