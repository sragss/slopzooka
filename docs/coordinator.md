# Experimental coordinator

Use **Ask** in the launcher header or **Ask SlopZooka** in a terminal's actions
menu to open the compact voice coordinator. It is a separate window and keeps
working when the launcher closes. Repeated opens reveal the same scene.

This is an opt-in development feature. It requires the matching companion,
headset build and session service. Updating the HTTP companion does not replace
an old session service or end existing terminals; the coordinator explains when
that service needs an explicit update.

## Speaking a request

Enable microphone/speech permissions if needed. Hold the microphone while
speaking, then release. Final words settle before the familiar two-second
countdown; tap × to cancel before submission. Delivery uses the same click/pulse
and transcript fade as terminal dictation. Pauses while holding do not send.
There is no keyboard or separate Send step in the normal flow.

Opening from the launcher supplies Global context on the selected Mac. Opening
from a terminal supplies its Mac, workspace and session. The small context label
shows that origin; **Global** clears workspace context. An active draft or
uncertain delivery keeps its original destination even if another terminal
reveals the coordinator. Terminal dictation remains terminal input; coordinator
voice goes to the structured Pi endpoint and never types into an arbitrary PTY.

Pi can find projects, create and name a workspace, start an owned Codex worker,
queue follow-ups, and open/close explicitly requested native previews. Codex
performs project setup and computer use. Its normal terminal attaches to the
same backend and thread. Ordinary follow-ups queue; explicitly requested
steering targets the observed active turn and fails if it changed.

Examples:

- “Launch Poncho2 in a new workspace named Login verification. Have its agent
  get iOS running and show me a preview on my headset.”
- From that coordinated terminal: “Click through the login and stop at Settings.”
- “Close the iPhone preview, keeping its app and terminal running.”

These are intended workflows, not claims that every project's setup is tested.
The coding worker reads the actual project and reports missing capabilities.
Existing ordinary terminals provide useful context but are not automatically
adopted as controlled workers. A multi-workspace command still has to respect
the native-input and worker limits below.

The main panel shows a short response and current activity. **Details** shows
full replies, worker results and required approvals. A historical acknowledgement
is labeled as such; it is not proof of completion or physical preview visibility.

**Stop** stops further coordinator actions and cancels only the submissions owned
by its latest request. It preserves workspaces, terminals, apps and unrelated
queued tasks. An uncertain cancellation stays visible rather than claiming the
agent stopped. Closing the window cancels unsubmitted voice/countdown, while an
uncertain submission retains its ID for Retry. Already accepted work keeps running.
Reopening refreshes its state without resubmitting. Ending the terminal explicitly
ends its owned backend; merely closing that terminal window does not.

Headset previews remain explicit requests. A disconnected headset returns
“not available right now”; a requested coding task may still run on the Mac.
Preview intent is not queued for an offline headset.

## Mac configuration

Set `SLOPZOOKA_COORDINATOR_CONFIG` to an owner-only JSON file when launching the
companion. The setting is inherited by the packaged companion as well as the
source host. The file contains `model`, `apiKey`, `codexExecutable`, optional
`workerModel`, and optional `nativeControl`. Store it outside the repository with
mode `0600`; do not put credentials in prompts or commit them. Restart the HTTP
companion after changing this configuration.

Pi uses the configured OpenAI API credential; the Codex backend uses the user's
normal local Codex authentication and settings. The coordinator credential is
not supplied to worker launch arguments or tools. `codexExecutable` must be an
absolute executable path. The worker requires the experimental remote app-server,
thread queue and TUI attachment interfaces; stock CLI versions are not all
interchangeable. Qualification on this Mac uses the installed ChatGPT-bundled
Codex `0.167.0-alpha.3.2`, Pi packages `1.4.0`, and `gpt-5.6-sol` for both models.

`nativeControl: true` opts into the user's installed ChatGPT native computer-use
runtime. The adapter reads its versioned MCP manifest; it does not redistribute
vendor binaries, extract another task's credentials, or provide browser-extension
access. The worker receives the runtime's live guidance. Missing or changed
installation, permissions, or tools fail visibly. This is an unstable integration,
not a supported third-party API or a release commitment.

Only one coordinated native-control worker may remain alive at a time. Reuse it
for multiple apps/previews, or end its terminal before starting another. This
avoids two managed native workers competing for foreground input. It does not
coordinate unmanaged desktop agents or human input; those remain a test constraint.

## Current limits

- Speech uses the existing terminal capture and hold-to-talk UX. GPT Realtime,
  gaze inference and a wrist entry point are not implemented. The new voice
  window still needs its own physical-device UX pass; the earlier device gate
  established the backend/control path through the typed test surface.
- Newly created coordinated workers only; existing arbitrary Codex terminals
  cannot be adopted. No Pi-owned direct computer-use loop or browser authority.
- Native command/file approvals and empty MCP confirmation forms have explicit
  Allow once/Decline UI. Other questions/forms are rejected with a clear error;
  large approval requests are not truncated and silently approved.
- Pi conversation and request deduplication live only in the HTTP process.
  Worker bindings live in the retained session service. An HTTP restart loses
  conversation history, while the worker and its terminal survive. Inspect state
  before resending an unconfirmed creation across a restart; there is no durable
  exactly-once promise.
- Limits: eight workers, eight client conversations, 64 coordinator requests per
  HTTP lifetime per client, 128 follow-up correlations per worker, 16 tool calls
  and two minutes per coordinator turn. Restarting the HTTP companion resets
  conversation limits without ending terminals. Worker request limits require
  a new worker. These are bounded experimental limits, not a long-running job system.

See [the voice-window plan and device gate](../.plans/2026-11-17-coordinator-voice-window.md)
for qualification and the isolated headset test.
