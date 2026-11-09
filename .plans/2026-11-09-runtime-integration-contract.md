# Review item #1: the Codex runtime integration contract

November 9, 2026. This consolidates the native reuse, desktop/browser investigation and live Pi work into a decision boundary. **Native control is technically reusable from our own Pi process, with either GPT or Claude. Independent use of Codex's Chrome backend is not yet provisioned. Neither result establishes a supported shipping API.**

See the [original native experiment](2026-11-08-codex-runtime-reuse.md), [browser bootstrap trace](2026-11-09-background-browser-control.md#8-desktop-bootstrap-traced-after-the-owned-task-failure), [Pi/GPT result](2026-11-09-pi-cua-probe.md), [Pi/Claude result](2026-11-09-claude-cua-compatibility.md) and [new evidence](evidence/2026-11-09-browser-runtimes/claude-and-runtime-contract.json).

## One integration label hides several separate contracts

| Boundary | Who owns it | What is established |
| --- | --- | --- |
| Model inference and tool selection | Pi plus selected model API | Live GPT and Opus both use the same native tools. An API key authorizes model inference; it does not authorize the desktop browser host. |
| MCP client and model-facing tools | Our process plus the genuine packaged runtime | stdio initialize/list/call, current tool descriptions/schemas, first-use guidance, text/images, scoped elicitation and owned-process close all exercised. |
| Native execution and OS permissions | Installed Codex native helper | Real AX/input/screenshot effects on the disposable app. Existing helper installation and macOS grants are prerequisites; production permission attribution is not qualified. |
| Specialized browser authorization | Desktop access host and lifecycle registry | Desktop-created tasks pass. Independent MCP and external App Server paths fail different prerequisites. |
| Browser target control | Browser service, extension, per-session tab ownership | Working desktop fixture evidence; independent Pi/terminal access and concurrent consumers remain open. |
| Native helper lifetime, updates and redistribution | Vendor installation plus our integration policy | Some process isolation tested; cold start, helper failure, upgrades and shipping permission remain gates. |

MCP is the usable boundary. Importing a private JavaScript client, copying a plugin manifest or knowing a socket path is not the same as obtaining the surrounding host lifecycle.

## Native startup: new source evidence and live lifecycle check

Inspection of the installed `targets/mac/native-pipe.js` shows:

1. It first connects to the native helper socket and performs a versioned ping.
2. If the socket is unavailable and a host-services pipe was supplied, it asks that host to `ensureService` for computer use.
3. Without that host-services pipe, it uses the trusted runtime's Launch Services capability to open the configured helper app, falling back to the installed helper location or bundle identifier.
4. It reconnects and validates the client/server API version. Version mismatch is an explicit error.

Our independent launcher does not inherit the desktop host-services pipe. This source path provides a plausible way to start the helper without the desktop UI. **It does not prove cold startup with ChatGPT closed:** our live tests ran with the installed desktop environment available and its helper warm. Do not require the desktop UI to be open solely from habit, but do not advertise independence until the cold case is measured.

We also ran a read-only two-client test against the completed fixture. A and B each attached; we closed A's MCP process; B stayed alive and obtained a fresh observation with the correct counter/text. Both owned child processes exited on cleanup. This qualifies **connection lifetime isolation**, not concurrent native input, separate keyboards, helper-crash isolation or cancellation of a script already executing in the helper.

The inspected native client queues requests on its own connection. That is not evidence of global arbitration between all callers. SlopZooka must still coordinate shared foreground input regardless of model choice. The first lifecycle script attempt had a diagnostic bug—reading the transport's PID after close, when it had been cleared. Capturing the PID before close fixed the probe; that failure is not a runtime defect.

## A real capture failure surfaced during the comparison

After replacing the disposable app with a fresh instance, a GPT baseline returned ScreenCaptureKit error `-3811`, described as failure to start a stream due to audio/video capture failure. The fixture's independent state remained counter 0 with empty text. The model stopped and the error is recorded. We have not established whether this arose from target teardown/startup timing, helper state or another capture condition.

This makes rapid target closure/relaunch and capture readiness an explicit runtime acceptance case. A successful AX attachment is not proof a screenshot stream can start. Surface those states separately. Never automatically replay an input sequence because capture failed: first establish what actions, if any, already took effect. The comparison's retry used a fresh connection only after independently verifying unchanged fixture state; the fresh connection succeeded, with state and screenshot independently verified. Both outcomes are retained in the evidence. A successful retry does not establish the failure's cause or an acceptable recovery SLA.

## Chrome: the missing object is a desktop-owned session

The earlier trace identified generated configuration from `appServices.threadConfiguration.readMcpConfig`, rather than the static manifest. That configuration carries the browser access-host connection, executor identity and public signature-verification key. Browser requests also carry actual session/turn context. The desktop host validates the caller and returns a signed decision tied to the request.

This follow-up inspected two details more closely:

- The packaged macOS host invokes a native socket-peer authorizer. We have inspected its call boundary, **not** proven which external executable identities it would accept.
- The desktop registry observes thread start/resume requests and replies, records session-to-executor relationships and resolves access against its current principal/Work state. A generated UUID or an external model's concept of a “turn” does not create that lifecycle association.

There are consequently several independent gates: process/peer admission; executor/session ownership; account entitlement; and website/tab permissions. Successfully installing the extension or accepting a website does not satisfy the earlier gates. A valid model API credential is separate again.

| Attempt | Actual outcome | What it establishes |
| --- | --- | --- |
| External stdio MCP, model-free or Pi/GPT or Pi/Opus | Missing-current-turn rejection | The runtime starts; independent browser session ownership is missing. |
| Our own real App Server task | Browser access host unavailable | A genuine Codex turn alone is insufficient. |
| Desktop parent creates a desktop child | Child completes Chrome fixture | Desktop provisioning works on that path; our outside companion's access to that task interface remains unqualified. |
| Read another task's transcript | Observations can be read; runtime status may differ across owners | Transcript visibility does not transfer execution ownership or qualify Stop. |

Public App Server documentation provides generic task and MCP methods. The inspected 106-method schema has no desktop `readMcpConfig` or browser enrollment method. Current browser-extension documentation describes desktop-mediated use; it does not establish an external Pi embedding contract. This is a scoped negative finding, not proof that no private or future interface exists. [App Server](https://learn.chatgpt.com/docs/app-server#api-overview), [browser extension](https://learn.chatgpt.com/docs/chrome-extension).

We checked the apparent alternative of Sign in with ChatGPT. Its documented registration flow grants API invocation against `https://api.openai.com/v1`; it does not document granting a local browser access-host session. It could solve inference billing/sign-in, but is not evidence that it solves this separate browser bridge. [Documented sign-in resource and scopes](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt#2-register-the-client-during-sign-in).

The useful next browser investigation needs a host-issued external-client connection and a defined create/approve/call/cancel/end lifecycle. Reusing another chat's credentials, simulating the host's signed answer or setting guessed executor IDs would not establish that contract. No such bypass or account-state mutation was attempted.

## Shipping and support are a separate decision

The public CLI's source availability is not a license for the bundled native/browser components. OpenAI's current Service Terms, section 10, describe limited use of installed Licensed Materials, restrict modification/redistribution/sublicensing and tie use to permitted Services use. Whether and how those provisions apply to this exact integration needs confirmation under the user's applicable agreement. Neither local success nor the use of MCP grants a standalone redistribution or cross-model embedding right. [Service Terms, updated October 16, 2026](https://openai.com/policies/service-terms/).

Before committing to this runtime for a release, get a concrete answer on calling a user's existing installation from our companion, using non-OpenAI models with it, whether any component may be packaged, and what compatibility/support contract exists. Keep vendor binaries and copied guidance out of the repo/distribution meanwhile; our experiments dynamically use the installed provider. This is an unresolved product-dependency question, not a claim that the experiment established permission to ship.

## Small remaining qualification plan

| Gate | Concrete acceptance evidence |
| --- | --- |
| Cold native startup | In a coordinated desktop slot, close ChatGPT normally and stop the helper only when no task uses it. Start the companion probe through the genuine launcher; verify helper launch, approval, input and screenshot. Restart the desktop afterward. Record whether the companion's packaged identity changes permission attribution. |
| Target and capture recovery | Repeat close/relaunch with fresh identities; distinguish AX readiness from capture readiness. Reproduce or bound the observed `-3811` failure. Verify stale targets fail and no input is duplicated after an uncertain result. |
| Actual Stop and helper failure | Interrupt a bounded operation on the disposable fixture; establish what already happened and when further input stops. Then test recovery from helper failure without claiming rollback. |
| Browser provisioning | Obtain a legitimate host-issued connection for an outside caller, then demonstrate actual Pi and terminal Codex consumers and correct turn cleanup. If unavailable, make an explicit provider/delegation tradeoff rather than expand a private authorization clone. |
| Version changes | Qualify the exact manifest/runtime/helper tuple and tool schema after an update. Detect startup/schema/version mismatch before admitting input; retain the observed failure. Loading guidance dynamically reduces prompt drift but does not remove compatibility work. |
| Release dependency | Resolve the installed-runtime and cross-model use terms and operational support expectations before promising the feature to others. |

The next native integration can still stay small and experimental. No second coordinator, durable workflow store, window registry or private browser authorization service is warranted. This review also does not close items #2–#7: task ownership, parallel input, presentation, spatial scale, voice/context and away-from-Mac behavior remain their own decisions and tests.
