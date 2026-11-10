# Codex thread discovery and handoff

November 10, 2026. **Yes: local Codex history can be shared across the CLI, desktop and SlopZooka. Live continuation additionally requires joining the runtime that owns the thread.** SlopZooka currently starts ordinary `codex` in its terminal; it does not create a separate Codex conversation store. An “Open existing Codex thread” launcher action is a reasonable extension of the planned worker adapter, not a reason to build a conversation database.

**User-confirmed priority and shape: P2, with a dedicated thread-list tab or section in the existing launcher.** Native history/catalog/resume capabilities already exist; once the planned worker adapter supports the relevant runtime, the incremental feature is mostly launcher UI and selection-to-session binding. That reuse does not make arbitrary live-runtime adoption automatic. This feature and its desktop interoperability checks do not block the initial orchestrator/streaming rollout.

This investigation used official documentation, read-only installed-build inspection and metadata queries against the already-running local App Server. It did not start a model task, resume another conversation, restart a server or operate the desktop UI. The [evidence manifest](evidence/2026-11-10-thread-handoff/results.json) contains sanitized results and artifact fingerprints. The earlier [worker-delivery experiment](2026-11-10-worker-delivery-results.md) separately established live terminal/controller sharing in an explicitly owned runtime.

## Three different forms of sharing

| Capability                    | Finding                                                                                                                                                                                                                                                             | Consequence for SlopZooka                                                                                                  |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Discover saved conversations  | Codex state normally lives under `~/.codex`, configurable through `CODEX_HOME`. `thread/list` provides a paginated native catalog; history can be read without resuming.                                                                                            | Query the provider catalog. Do not scrape xterm output, copy transcripts or maintain a competing durable list.             |
| Continue a saved conversation | `codex resume <thread-id>` and App Server `thread/resume` support continuation. The CLI picker has directory filters, and stored provider/configuration matters.                                                                                                    | Reuse the native ID and original working directory. A new terminal presenter need not mean a new conversation or worktree. |
| Share a live worker           | The installed CLI supports `--remote` attachment, including a Unix socket. Our earlier live test demonstrated a TUI and structured controller using one runtime/thread. The desktop has a conditional shared-daemon transport as well as an independent stdio path. | Resolve the actual owning runtime. A second server reading the same history is not established as safe live attachment.    |

The official [state-location documentation](https://learn.chatgpt.com/docs/config-file/environment-variables#core-locations), [resume command](https://learn.chatgpt.com/docs/developer-commands#codex-resume) and [App Server reference](https://learn.chatgpt.com/docs/app-server) establish the public building blocks. This is local host/state sharing, not a promise that every ChatGPT cloud conversation appears in every local CLI. The desktop can present multiple hosts and conversation kinds; the launcher must retain host identity.

## What we established on this Mac

- Installed CLI and running managed App Server: **0.167.0**. Installed desktop: **ChatGPT 26.1103.60933**, build **25894**, bundle ID `com.openai.codex`. “Codex Desktop” here refers to the Codex functionality in that installed ChatGPT app.
- This shell has no `CODEX_HOME` override. The desktop's inspected home resolver also defaults to `~/.codex`. A read-only database metadata check corroborated that multiple native source kinds coexist in that home. Database paths/schema are implementation evidence, not our proposed API.
- `codex app-server daemon version` reported an existing server and its local socket. A new client performed only `initialize`/`initialized`, `thread/list` and `thread/loaded/list`. No daemon launch, thread resume or model call was needed.
- The server returned **three conversations scoped to this research worktree**, two idle and one active. All three were loaded. **This current conversation's exact `CODEX_THREAD_ID` matched the active catalog entry and the loaded-thread list.** Its native source is `vscode`; source labels should not be treated as a reliable description of the currently visible UI.
- Separate one-result source queries found `cli`, `vscode` and `exec` records in the same server catalog. No `appServer` source record was returned in that sample. These queries establish discoverability, not an end-to-end desktop rendering test.

The desktop's installed code calls `thread/list` for recent conversations. Its ordinary source filter is empty, which the native API defines as interactive sources (`cli` and `vscode`). It filters ephemeral and certain internal threads and has additional host/view selection logic. This supports shared discovery of ordinary local CLI threads; it does not guarantee that every experimental or automation thread appears in every sidebar.

The installed desktop also resolves the default home and has a transport branch that connects to the managed App Server socket when its local-daemon mode and compatibility checks allow it. Otherwise it can launch a stdio backend. **We did not establish which branch every open desktop window currently uses.** Do not make a private environment flag a product requirement or alter the user's daemon configuration just to make handoff work.

### CLI and desktop entry points

The installed CLI exposes these useful user-facing commands:

```sh
codex resume --all                         # Browse saved sessions across directories
codex resume <thread-id>                   # Continue one native conversation
codex agents                              # Browse the connected server's agents
codex resume --remote unix:// <thread-id>  # Explicitly use the default local socket
```

Use an explicit socket URL for a separately owned runtime. `--include-non-interactive` broadens the resume picker's source scope. `--all` removes its cwd restriction; it does not mean “every source on every host.” The CLI can ask which working directory to use when it differs from the saved one. Use the saved cwd deliberately; do not silently relocate a resumed task. [Developer commands](https://learn.chatgpt.com/docs/developer-commands).

Installed-build inspection found a registered `codex` URL scheme, a parser for `codex://threads/<thread-id>`, a link generator and optional `hostId` handling. That is a promising **Open in desktop** action. It is an inspected, version-specific interface, not a documented stable third-party contract or a visually tested link in this investigation. `codex app [path]` is documented for opening a workspace, not for selecting a particular thread. A production adapter should capability-check deep links and retain a copy-ID/resume-command fallback.

## Why a thread might not appear or might behave differently

1. **Different state or host.** A different user, `CODEX_HOME`, SQLite-home configuration, remote host or ephemeral run can change visibility. Our worker experiment intentionally used a private temporary Codex home, so those disposable threads were not a test of normal desktop discovery. `SLOPZOOKA_HOME` is separate from `CODEX_HOME`; do not isolate the latter merely to isolate companion state.
2. **Catalog filters.** `thread/list` defaults to interactive sources and non-archived threads; cwd, provider, section and search filters also apply. In particular, `sourceKinds: []` does not mean all kinds, whereas `modelProviders: []` means all providers. Request explicit additional kinds only when the UI needs them. [Native filters](https://learn.chatgpt.com/docs/app-server#list-threads-with-pagination--filters).
3. **Different live owner.** `--no-daemon`, an explicitly owned App Server or a desktop stdio backend can use the same stored history while having a different in-memory runtime. `notLoaded` is the responding server's state; it is not proof that no other process owns that thread. A filesystem match is not sufficient authority to take over a live worker.
4. **Different capabilities.** Conversation history does not transport an app's complete tool environment, CUA provisioning, approvals UI or browser ownership into another harness. Official Appshots documentation explicitly says an existing attachment remains in CLI history although the CLI cannot create a new appshot. Preserve the owning runtime when possible and qualify our scoped MCP/provider tools on resume. [Appshot limitation](https://learn.chatgpt.com/docs/appshots#limits-and-troubleshooting).
5. **Unavailable project or incompatible provider.** The original worktree may have been removed. Current App Server documentation reports `modelProviderMismatch` when resuming under a different saved provider; history reading and explicitly forking are separate options. Do not silently create a new worktree, switch providers, broaden permissions or fork the task. [Resume semantics](https://learn.chatgpt.com/docs/app-server#start-or-resume-a-thread).

## P2 launcher thread section

Add a dedicated **Threads** tab or section to the existing launcher, backed by Codex's native catalog. Show recent title, project/worktree, host and native activity status, with lightweight search/project filtering. Selecting a row performs **Continue Codex thread** through the worker/session adapter. The exact tab-versus-section layout remains a UI choice. A separate transcript viewer is not required for this slice; opening the existing terminal UI supplies the conversation view. Pi can invoke the same selection action without maintaining its own thread catalog.

On selection, the existing Mac session owner resolves the native thread and working directory:

- If SlopZooka already has its terminal session, reopen/focus that existing presentation through `WindowGateway`.
- If the thread is loaded in a known compatible runtime, attach a new terminal presenter to that exact runtime and thread. The original agent remains the worker; a second presentation is not a second coding task.
- If it is a saved inactive conversation with no conflicting live ownership, resume it using the selected provider runtime and original cwd, and register that binding with the existing session owner.
- If ownership, runtime access or cwd is unavailable, show the specific condition. Do not pretend that opening saved history adopted another running TUI.

Persist the native thread identifier as part of the session/workspace binding, with its stable host/provider identity. Resolve the current runtime endpoint and incarnation when attaching; do not persist tokens/socket details in Vision window records. Codex thread ID, SlopZooka terminal-session ID, workspace ID and Vision window ID remain distinct. Two terminals in the same directory are not sufficient evidence that they show the same thread.

Codex remains authoritative for conversation history, title and task state. SlopZooka keeps its existing ownership of terminals, workspace metadata and desired window layouts. A thread title can seed a useful workspace name, while explicit human workspace names remain protected. There is no new orchestration database, conversation synchronization service or parallel window manager in this proposal.

An optional reverse action is **Open in Codex desktop** for a bound thread, using the qualified link. It is not required to ship the launcher thread list. Do not equate that action with transferring process ownership or ending the SlopZooka terminal. Viewing/closing a presentation, stopping a turn and ending a worker remain different actions.

## Effect on the execution plan

The existing owned-runtime experiment remains a valid demonstration of worker delivery. This research adds a production choice: **prefer connecting the adapter to an already-running compatible shared runtime when available**, because it preserves native interoperability. Retain an explicitly owned runtime as a supported arrangement when necessary, with honest live-sharing limits. Shared saved history is useful in either arrangement; a private production `CODEX_HOME` would deliberately give up default catalog sharing.

Keep runtime selection and compatibility in the Mac worker adapter under the existing session owner. This is a small extension to launch/attach semantics, not a prerequisite networking or window rearchitecture. Do not ship an automatic private-daemon migration or restart policy based only on this investigation.

## Small P2 acceptance test

Run with the P2 launcher work, not as another prerequisite to the initial rollout. No headset is required for the interoperability portion. Use one clearly marked disposable persistent conversation and the normal user configuration, leaving other workers alone:

1. Launch through the SlopZooka session service, capture the native thread/runtime binding, then open that exact thread in the desktop. Verify visible history and title, original cwd and one worker. This qualifies the actual sidebar/deep-link path.
2. Start one bounded task, attach the other client to the same runtime, and verify identical active-turn identity, streamed result and queue/Stop state. Merely seeing matching transcripts does not pass the live test.
3. Reverse direction: select a desktop-origin local thread from the SlopZooka catalog, resume or attach as appropriate, then close/reopen only its terminal presentation. Verify no duplicate worktree or worker and that required SlopZooka/browser tools remain available.
4. Exercise one different-runtime case and a missing-cwd case. Require explicit unavailable/saved-history behavior instead of silently starting a competing worker or relocating the task.

The metadata discovery and earlier same-runtime delivery checks have passed. **The real desktop/SlopZooka round trip, automatic adoption of arbitrary existing processes and tool parity across those clients remain untested.** They are a focused interoperability qualification, not a new broad feasibility project.
