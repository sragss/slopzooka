# Preview MCP physical gate — November 16, 2026

**PASS for the opt-in preview lifecycle on Local Network and Direct.** Product
commit 7ba2598, operator rig f31398c, draft PR #58. The wearer checks ran on
November 17 at approximately 02:31–02:34 UTC (November 16 local).

## Observed behavior

The real packaged SDK stdio server enumerated native sources and requested the
Simulator preview named “Login verification.” The wearer confirmed a fresh,
phone-shaped stream, then closed the launcher. MCP renamed it to “Login verified”
without interrupting capture and opened the independent Mac fixture alongside it.
Both showed the updated nonce. MCP close dismissed only the Simulator; the Mac
stream continued. Reopen restored the Simulator.

A second independently initialized MCP client requested the existing Mac source
and received the same preview ID at the unchanged layout revision (7). It did not
create another stream. This is multi-client reuse evidence, not a test of two
simultaneously reasoning coding agents.

The wearer switched to Direct and closed the launcher again. Host diagnostics
recorded `awdl0` peer admission at 02:32:52.292 UTC and actual Direct media ingress.
MCP renamed the Mac header to “Admin on Direct” and closed the Simulator while the
Mac continued moving. Reopen produced “iPhone on Direct”; both previews showed the
fresh nonce 9b45ada8, with Mac Count 4. Every wearer verdict was positive.

The stream connection records corroborate rename without capture restart and
separate viewer closure. Six nonempty capture summaries reported 7,795 offered
frames and zero encoded drops. These are sender counts, not measured display FPS
or latency. Zero-frame connection summaries are excluded from capture totals.

MCP closed both previews after the final verdict. The saved layout retained only
the two original test terminals, still running under the same test session-service
instance. Owned cleanup then stopped the test service/fixtures and removed only
Slz Preview Test from the headset. The user's installed companion instance and
available terminal service remained unchanged.

Sanitized evidence: [JSON](evidence/2026-11-16-preview-mcp-device.json).
Private run: `/tmp/slz-preview-validation/run-lvSW3h`. Raw window catalogs,
credentials and unrelated application titles are not included in committed evidence.

## Rollout scope and offline behavior

This qualifies the tools/window integration, not automatic deployment into every
Codex terminal. The MCP executable was bundled in the test Mac app and driven by
real SDK clients. No global Codex configuration was changed; this slot did not run
a live Codex model or CUA task. The installed real companion was not replaced.

At the time of this physical run, the MCP had **no explicit headset-online signal**. Its catalog `state`
reports Mac capture readiness. A reachable Mac accepts desired-layout changes even
when the headset is disconnected. Mutation results say `desired_state_acknowledged`
and `visibility: not_observed`; the agent should report the request was saved and
avoid saying it is visible. The headset reconciles the saved layout on reconnect,
subject to source availability. A source that disappears or gets a new provider ID
can still be unavailable at that point. Mac connection failures produce tool errors.
This slot did not physically test the offline/reconnect backlog.

Recommended next slice: provision the explicit companion/headset binding when
SlopZooka launches a Codex terminal, and define honest target connection/presentation
feedback using the existing lifecycle/transport owners. Do not infer online/offline
from Mac capture readiness or introduce a parallel window registry. Keep broad rollout
separate from merging this opt-in, operator-configured implementation.

### Subsequent user-directed policy change

After this physical pass, the user requested opt-in tool use with “not available
right now” rather than offline queuing. The follow-up implementation adds fresh
headset presentation probes and rejects offline writes, including conflict retries.
Server instructions prohibit automatic invocation/retry during normal laptop coding.
Those additions are covered by local HTTP/stdio and Swift tests; this earlier device
pass does not claim to exercise the subsequently added availability handshake.
