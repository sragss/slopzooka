# Owned browser extension: implementation and live evidence

Date: November 9, 2026. Follow-up to the [runtime integration contract](2026-11-09-runtime-integration-contract.md#an-owned-chrome-extension-is-a-bounded-alternative), implemented at the user's request. [Reproduction and tool reference](../experiments/owned-browser-probe/README.md). [Machine-readable evidence](evidence/2026-11-09-browser-runtimes/owned-extension.json).

## Conclusion

**An independent extension is now a working browser-control path.** Two callers can control different background tabs through our MCP/native-messaging/`chrome.debugger` implementation. Live Pi agents using GPT and Opus both completed the fixture concurrently and received screenshots. This removes the desktop-issued Codex browser-session prerequisite for this particular provider. It does not establish feature parity with Codex's broader browser runtime or settle the global-agent versus terminal-agent ownership policy.

The first useful implementation remained small: one extension worker, a native framing shim, a transient companion router and a standard stdio MCP adapter. Target leases and input queues have one owner in the worker, closest to actual CDP dispatch. The router creates per-connection caller identities; agents cannot impersonate another owner through tool arguments. Nothing is persisted and no production window, workspace, terminal or session registry was added.

## What ran

The real path was:

```text
two independent callers -> two stdio MCP processes -> private companion socket
  -> Chrome-launched native host -> our MV3 extension -> separate Chrome tabs
```

Chrome for Testing **157.0.8103.15**, Node **22.20.0**, MCP SDK **1.30.0**, Pi **1.4.0**, on this Mac. The extension loaded into a fresh temporary profile and its native-host manifest lived within that profile. No installation into the user's everyday Chrome, ChatGPT extension or protected runtime was changed. Playwright supplied the testing browser; it did not drive the agent tabs.

A separate test-only CDP connection typed `human-keeps-typing` into a third foreground fixture. The two agents' targets remained background tabs; the third tab stayed active, its document stayed focused, and its text and caret were intact. This is controlled simulated-user evidence, not a report from a person typing concurrently. The agent route needs no remote-debugging port; this test used one for its independent fixture observer.

| Case                              | Observed result                                                                                                                                |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Two independent MCP clients       | Different labels saved; each counter reached exactly 2 and Settings opened; no crossed fixture events                                          |
| Competing access                  | Same-tab claim, another caller's opaque target and an outside-origin open were rejected                                                        |
| Background observation            | AX state and an actual JPEG image returned through MCP                                                                                         |
| Navigation                        | Old refs rejected; fresh observation permitted the next action                                                                                 |
| Stop during input                 | Fixture beacon established the first click had entered its handler; all 12 queued increments were rejected; zero extra increments; B continued |
| Native host killed during a click | Pending call reported uncertain effects; reconnect invalidated the old target; explicit reclaim/read/action worked without mutation replay     |
| Tab closed externally             | Old target rejected; B's tab remained present                                                                                                  |
| MCP client disconnect             | Its lease was released and a new client reclaimed the existing tab                                                                             |
| Two live Pi models                | GPT and Opus each saved its own label, incremented twice, opened Settings, verified state and received an image through the same tool adapter  |

In the first successful concurrent model run, GPT (`gpt-6.1-sol`) took **20.4 seconds / 12 tool calls** and Opus (`claude-opus-5-5`) took **21.3 seconds / 10 tool calls**. Both had zero tool errors. These are single fixture completions, not a speed/cost benchmark or evidence that either model is preferable. Both final reports correctly distinguished the text label verified by AX from the portion visible in the scrolled screenshot.

The final repeat and exact artifact fingerprints are retained in the evidence JSON. No live terminal Codex task has yet been connected to this provider: the standard MCP server, independent clients and Pi model consumers are qualified. `--serve` prints a concrete temporary endpoint for that remaining acceptance check without editing global agent configuration.

## The failures were useful

1. **Native bridge resources under Documents failed.** Chrome's native child reported `Operation not permitted` reading the test launcher there. We moved only our dependency-free bridge files and generated configuration into the private runtime directory. The next native-host launch succeeded. This is a packaging/permission-attribution lesson; do not require broad Documents access merely to start the companion bridge.
2. **Headless success hid a headed-input failure.** Without focus emulation, real visible Chrome accepted mouse CDP commands, but both counters remained 0 and the event server received no clicks. Text filling still worked. A diagnostic repeat reproduced the same outcome. Tool success alone was therefore insufficient evidence of a successful action.
3. **Tab-local focus emulation fixed the measured case.** Enabling `Emulation.setFocusEmulationEnabled` at attachment made headed background mouse input work while the human fixture retained its active-tab state, document focus, value and caret. The final probe explicitly exercises headed mode. This emulates an active page; it is not evidence of multiple independent macOS foreground keyboards. It can change page visibility/focus assumptions and background throttling, so its rendering/power cost needs measurement at the intended window count. [CDP Emulation reference](https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setFocusEmulationEnabled)
4. **Immediate serve shutdown exposed a startup race.** The first `--serve` smoke test sent SIGINT as soon as the endpoint was printed, before the shutdown handler was registered; cleanup was not reported. Registering the handler before advertising the endpoint fixed that ordering. The repeated immediate-interrupt smoke test exited normally and reported cleanup. This change affected serve mode only, after the final browser/model acceptance repeats.

Stop and disconnect tests do not claim rollback. The worker revokes a lease synchronously before awaiting detach and checks it before subsequent commands. A mouse press or click already dispatched can have happened. Navigation can also race between individual protocol requests. The appropriate result is explicit uncertainty plus a fresh observation, not automatic replay.

## Implications for our architecture

- **Keep the common tool boundary.** Pi and a coding agent can consume the same MCP tools. Caller ownership and task-routing policy remain distinct from the provider implementation. There is no need to automate a desktop chat composer.
- **Use target-local browser input where available.** Independent background browser tabs are feasible on this configuration. Generic native Mac CUA still shares desktop focus/input and needs separate arbitration.
- **Treat page identity and presentation as the next join.** This probe creates tabs, not spatial windows. Associate the controlled browser target with the exact presented content through the existing Mac service and Vision `WindowGateway`. Native window capture of one selected Chrome tab is not automatically a separate continuous stream for every background tab.
- **Retain a narrow adapter.** The browser worker owns its CDP leases; the companion owns authenticated caller/task admission and existing process/workspace services. Do not grow the prototype router into another durable coordinator or window manager.
- **Separate observation from streaming.** JPEGs in this experiment are discrete model observations. Our proposed native video path and the exact background-tab presentation path remain separate work.

## Remaining qualification

The next useful acceptance test is a real terminal Codex instance using the printed `--serve` MCP configuration while Pi owns a different tab, followed by a physical click on the extension's Stop control and explicit human takeover. Then connect one controlled target to the real Vision presentation boundary. No further private Codex browser-authentication emulation is needed to demonstrate that owned path.

Before treating it as a general browsing provider, qualify current stable Google Chrome loading/onboarding, permission repair and ownership visibility, real app controls and frames, page-driven navigation/popups, dialogs, closed/replaced targets, worker eviction, companion restart, upgrades and longer sessions. Separate tabs still share a profile and cookies. A local private socket is not protection from every process under the same user. Origin grants and caller admission need the actual companion's policy before allowing arbitrary sites.

Still untested here: physical keyboard/human Stop UX, signed-in personal profiles, background-tab video to Vision, multi-window rendering budgets, macOS lock/sleep, and general native-app concurrency. Focus emulation is not a locked-computer availability guarantee. None of these should be inferred from the successful fixture.

## Verification and references

The probe has bounded native-message framing tests and real-browser acceptance tests in both headless and headed Chrome. The headed run also exercises two concurrent Pi/model consumers. Local screenshots were inspected; only fixture state, run metadata and hashes are committed.

Repository verification also passed on this follow-up: `pnpm test:vision-state`, `pnpm typecheck`, all **43** companion tests, `pnpm test:terminal-keyboard`, `pnpm format:check`, `pnpm build:harness` with no generated-asset diff, and the full visionOS simulator build. Production source code is unchanged. The earlier November 8 WebKit viewport timeout remains a historical unresolved failure cause; this successful rerun does not explain it or establish physical headset reliability.

Primary references used for the implementation:

- [Chrome debugger API](https://developer.chrome.com/docs/extensions/reference/api/debugger): tab-targeted CDP transport, domain restrictions and detach events.
- [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging): Chrome-owned host process, exact extension origin, native-length framing, directional message limits and per-profile host lookup. The shim bounds host-to-Chrome messages below 1 MB; large image replies travel in the opposite direction and have a smaller probe-specific bound than Chrome's maximum.
- [Extension worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle): native ports and active debugger sessions affect worker lifetime, but do not eliminate restart handling.
- [CDP Emulation](https://chromedevtools.github.io/devtools-protocol/tot/Emulation/#method-setFocusEmulationEnabled) and [Input](https://chromedevtools.github.io/devtools-protocol/tot/Input/): page-local focus and input primitives, rather than OS-wide keyboard/mouse injection.
- [Playwright extension testing](https://playwright.dev/docs/chrome-extensions): isolated Chromium/Chrome-for-Testing loading; ordinary branded Chrome's removed side-loading flags are a reason not to equate this test setup with a shipping installer.

These sources describe components. The ownership protocol, tool schema and architecture above are our implementation, not a Chrome-prescribed end-to-end product.
