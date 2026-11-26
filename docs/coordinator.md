# Experimental coordinator

Use **Ask** in the launcher header or **Ask SlopZooka** in a terminal's actions
menu to open the compact voice coordinator. It is a separate window and keeps
working when the launcher closes. Repeated opens reveal the same scene. Resize either edge to give the conversation more room.

This is an opt-in development feature. It requires the matching companion,
headset build and session service. Updating the HTTP companion does not replace
an old session service or end existing terminals; the coordinator explains when
that service needs an explicit update.

## Speaking a request

Enable microphone/speech permissions if needed. Hold the microphone while
speaking, then release. Final words settle before the familiar two-second
countdown; tap × to cancel before submission. Delivery uses the same click/pulse
and transcript fade as terminal dictation. Pinch the Ask mic once and keep holding while looking elsewhere or pausing between phrases. Releasing that pinch starts the send countdown. Hold the mic again before delivery to append to the same message. If visionOS cancels the gesture, Ask pauses with the draft retained.
Ask accepts another utterance while the coordinator is working. It displays
accepted follow-ups as **Queued** and runs them in order with their captured
destinations. The mic sits at the bottom of the right edge. A matching **Stop Ask** button appears directly above it while Ask is processing a request. Both leave the chat area clear. Recent repo
and worktree names from the selected launcher's catalog help interpret spoken
names. The model can ask about ambiguous matches.

Opening from the launcher supplies Global context on the selected Mac. Opening
from a terminal supplies its Mac, worktree and session. The small context label
shows that origin; **Global** clears worktree context. An active draft or
uncertain delivery keeps its original destination even if another terminal
reveals the coordinator. Terminal dictation remains terminal input; coordinator
voice goes to the structured Pi endpoint and never types into an arbitrary PTY.

A **repo** holds a Git history. A **worktree** is a named checkout on the Mac with its own branch from that repo. One repo can have several worktrees. A **terminal** runs a session in a worktree, and a **thread** is a Codex conversation. Ask can start a worktree from an existing repo or create a new local repo with its first worktree. “Create a new project called Email Test” creates `email-test` on the Mac. Publishing requires a separate explicit request to the coding agent.

Pi can find repos, create and name a worktree, start an owned Codex worker,
queue follow-ups, and open/close explicitly requested native previews. Codex
performs repo setup and computer use. Its normal terminal attaches to the
same backend and thread. When you change the direction of work already underway, Ask steers the observed active turn. If that turn has changed, Codex rejects the steer. Separate or deferred tasks enter the terminal’s queue. Ask shows **Queued in terminal · waiting to start** until Codex takes up that message.

When you ask to see an app on the headset, Pi includes the intended worktree, app and screen in the coding agent’s task when known. If Codex will present a native window, Pi points it to its paired preview MCP. If Pi will present the window, Codex only needs to prepare it and identify the source. Ordinary coding requests carry no preview setup steps.

Examples:

- “Launch Poncho2 in a new worktree named Login verification. Have its agent
  get iOS running and show me a preview on my headset.”
- From that coordinated terminal: “Click through the login and stop at Settings.”
- “Close the iPhone preview, keeping its app and terminal running.”

These are intended workflows, not claims that every repo's setup is tested.
The coding worker reads the actual repo and reports missing capabilities.
Existing ordinary terminals provide useful context but are not automatically
adopted as controlled workers. A multi-worktree command still has to respect
the native-input and worker limits below.

The chat fades at either edge when messages continue beyond it. Ask shows one scrolling conversation across voice requests and worktree changes on
that Mac. Your complete utterances and concise coordinator replies remain visible.
Markdown headings, lists, emphasis, code and links render natively. Completed worker
results contribute a short excerpt from the final reply's opening outcome;
**Details** and the terminal retain fuller output. Reconnection restores that same
final reply rather than combining earlier progress messages with it.
Each exchange tracks its own worker delivery, so later tasks cannot rewrite an
earlier result. If a worker disappears mid-task, that exchange shows **Agent unavailable**
until the Mac can confirm its progress again. Completed results stay readable.
Activity appears inside the exchange it describes. If one of its tasks needs attention
while another is still running, **Stop agent** remains available once Ask finishes dispatching.
Ask follows new replies and progress while you’re at the bottom. Scroll up to
keep your place while reading earlier messages. Return to the bottom to follow
new activity again.

The line below **Ask SlopZooka** shows Global or the terminal context. Opening
Ask from a terminal targets the Mac that owns it, including a restored terminal.
If that Mac differs from the launcher's selection, Ask shows the destination
companion and **Use connected Mac** switches to the launcher's global context.

Ask can find older or in-flight Codex threads in this Mac's saved catalog. For
example, ask “Find the thread about the Poncho2 pairing UX.” It searches or
pages through recent metadata and can peek at three short user/assistant
excerpts at a time. Looking up a thread leaves its session and input alone.
Say “pull it up” to open the matched original thread in a terminal through the same resume action as the launcher. The catalog can only show what Codex has persisted.

“Here” and “windows” mean SlopZooka by default. The coordinator reads this headset's
saved terminal/preview layout, current session names, worktree associations and
matching preview sources. This is desired layout, not proof of physical visibility
or gaze; Ask and launcher utility panels are excluded from that content-window count.
Unshared Mac capture sources are a separate catalog. “Name this terminal Login” uses
the session rename API; native preview naming uses the existing layout owner. These
actions do not require a coding worker or Mac terminal title manipulation.

**Stop Ask**, above the microphone, cancels the current coordinator turn. Agent
work already sent to the Mac continues. A delayed tap cannot stop a newer Ask
request.

**Stop agent** appears in a request’s exchange once Ask has finished dispatching
and its agent work is queued or running. It targets that request’s submissions,
even if a newer request is visible or another terminal has focus. Codex removes
those queued submissions and interrupts a running turn that contains one of them.
If a steer joined an existing Codex turn, interrupting it stops the whole turn.
Worktrees, windows, terminals and unrelated queue entries stay open or queued.
If cancellation cannot be confirmed, that exchange offers **Retry Stop agent**.

Closing the window cancels unsubmitted voice/countdown, while an
uncertain submission retains its ID for Retry. Already accepted work keeps running.
Reopening refreshes its state without resubmitting. If the reply was lost after
acceptance, **Retry** can confirm that same request while the coordinator is busy;
it does not submit a new task. Queued voice requests start after the current coordinator turn finishes. Worker
reconnection restores turn progress/results. If resuming the connection fails,
Ask keeps it unavailable and retries on a later status refresh without resubmitting
the task. A cancelled queued task is shown
as interrupted instead of remaining queued. Ending the terminal explicitly
ends its owned backend; merely closing that terminal window does not.

Ask can retry a transient model connection failure once while opening the
model response. Earlier tool actions and worker submissions keep their original
receipts. If the model still fails, the exchange shows the failure category.

Headset previews remain explicit requests. A disconnected headset returns
“not available right now”; a requested coding task may still run on the Mac.
Preview intent is not queued for an offline headset.

## Mac configuration

Save an owner-only `coordinator.json` in the companion’s data directory
(`~/.slopzooka` by default). Set `SLOPZOOKA_COORDINATOR_CONFIG` at launch to use
a different file in either the packaged companion or the source host. The file contains `model`, `apiKey`, `codexExecutable`, optional
`workerModel`, and optional `nativeControl`. A configured `workerModel` overrides Codex’s default at thread creation. Omit it to inherit the app-server default. Store it outside the repo with
mode `0600`; do not put credentials in prompts or commit them. Restart the HTTP
companion after changing this configuration.

Pi uses the configured OpenAI API credential; the Codex backend uses the user's
normal local Codex authentication and settings. The coordinator credential is
not supplied to worker launch arguments or tools. `codexExecutable` must be an
absolute executable path. The worker requires the experimental remote app-server,
thread queue and TUI attachment interfaces; stock CLI versions are not all
interchangeable. Qualification on this Mac uses the installed ChatGPT-bundled
Codex `0.167.0-alpha.3.2`, Pi packages `1.4.0`, and `gpt-5.6-sol` for the original fixture.

`nativeControl: true` opts into the user's installed ChatGPT native computer-use
runtime. The adapter reads its versioned MCP manifest; it does not redistribute
vendor binaries, extract another task's credentials, or provide browser-extension
access. The worker receives the runtime's live guidance. Missing or changed
installation, permissions, or tools fail visibly. This is an unstable integration,
not a supported third-party API or a release commitment.

Each coordinated worker has its own terminal, Codex thread and native REPL.
Coding tasks can run concurrently. An active native REPL interaction reserves
foreground input across workers on the same session service until completion,
reset, disconnect, or 60 seconds idle between calls. A competing native tool call
receives a busy result; after an idle expiry the worker must reset and observe
again. Human input and other applications operate outside this mechanism.

## Current limits

- Speech uses the existing terminal capture and hold-to-talk UX. GPT Realtime,
  gaze inference and a wrist entry point are not implemented. The new voice
  window passed its initial physical voice/reopen/follow-up/Stop gate. The updated
  scrolling conversation, naming/context behavior and foreground notification
  clearing still need their next physical-device pass.
- Newly created coordinated workers only; existing arbitrary Codex terminals
  cannot be adopted. No Pi-owned direct computer-use loop or browser authority.
- Native command/file approvals and empty MCP confirmation forms have explicit
  Allow once/Decline UI. Other questions/forms are rejected with a clear error;
  large approval requests are not truncated and silently approved.
- Pi conversation and request deduplication live only in the HTTP process.
  Worker bindings live in the retained session service. An HTTP restart loses
  conversation history, while the worker and its terminal survive. Within that
  lifetime, the conversation keeps all accepted exchanges up to the existing
  64-request limit; long model tool transcripts are compacted into earlier exchange
  excerpts and target IDs rather than silently starting an unrelated conversation. Inspect state
  before resending an unconfirmed creation across a restart; there is no durable
  exactly-once promise.
- The Mac session service allows up to 20 coordinated workers across its paired clients. Each launched worker has a Codex backend and a terminal, and its terminal also counts toward the service’s 100-session limit. A worker stays available for follow-ups after its turn finishes. **End Session** frees its slot. If a worktree was created before the limit was reached, ask to start the worker in that existing worktree.
- Other limits: eight client conversations, 64 coordinator requests per
  HTTP lifetime per client, 128 follow-up correlations per worker, 16 tool calls
  and two minutes per coordinator turn. Restarting the HTTP companion resets
  conversation limits without ending terminals. Worker request limits require
  a new worker. These are bounded experimental limits, not a long-running job system.

See [the voice-window plan and device gate](../.plans/2026-11-17-coordinator-voice-window.md)
for qualification and the isolated headset test.


## Local context probe

Run `pnpm --filter @slz/mac-companion exec tsx ../../scripts/coordinator/context-smoke.mts`
to exercise the configured live model against disposable HTTP fixtures. It checks
SlopZooka window counts, terminal/preview naming and follow-up memory without
controlling any actual app. It uses the development coordinator configuration (or
`SLOPZOOKA_COORDINATOR_CONFIG`); headset availability is substituted in this probe.
It does not establish physical presentation or native focus behavior.
