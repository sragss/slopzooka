# Experimental coordinator

The launcher's **Ask** tab sends a typed request to an ephemeral Pi agent in the
Mac companion. Pi can find projects, create and name a workspace, start an owned
Codex worker, queue a follow-up, and open or close requested previews. Codex does
the project setup and computer use. Its normal terminal attaches to the same
backend and thread; Ask does not type prompts into an arbitrary terminal.

This is an opt-in development feature. It requires the matching companion,
headset build and session service. Updating the HTTP companion does not replace
an old session service or end existing terminals; Ask explains when that service
needs an explicit update.

## Using Ask

Choose **Global** for a new task, or choose an existing coordinated workspace in
the destination picker for a follow-up. Selection is captured when you send; a
later focus change cannot redirect the request. Ordinary follow-ups queue in
Codex. Explicit steering targets the observed active turn and fails if it changed.
The worker card shows progress, requests for supported approvals, and its latest
response. A coordinator reply saying the worker started is not task completion.

Examples:

- “Launch Poncho2 in a new workspace named Login verification. Have its agent
  get iOS running and show me a preview here.”
- With that workspace selected: “Click through the login and stop at Settings.”
- “Close the iPhone preview, keeping its app and terminal running.”

These are intended workflows, not claims that every project's setup is tested.
The coding worker reads the actual project and handles missing tools or permissions.

**Stop this request** stops further coordinator actions and cancels only the
worker submissions owned by that request. It preserves workspaces, terminals,
apps and unrelated queued tasks. A resource already created when Stop arrives
is kept. Closing Ask does not stop work. Ending the terminal explicitly ends its
owned backend; merely closing its window does not.

Headset previews remain explicit requests. A disconnected headset returns
“not available right now”; the coordinator may still run a requested coding task
on the Mac. Preview intent is not queued for an offline headset, and a saved
window layout is not proof that the user saw the stream.

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

- Typed launcher entry only: no voice/realtime session, gaze inference, wrist
  entry point, or contextual action in existing terminal windows yet.
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

See [the implementation and device gate](../.plans/2026-11-17-coordinator-implementation.md)
for qualification and the isolated headset test.
