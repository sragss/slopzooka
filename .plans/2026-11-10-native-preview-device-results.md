# Native preview and Direct recovery: physical results

Date: 2026-11-10, approximately 23:11–23:30 UTC. Draft PRs
[#56](https://github.com/sragss/slopzooka/pull/56) and
[#54](https://github.com/sragss/slopzooka/pull/54). Candidate `8aaef64` plus the
native control-pipe fix below. Test apps used separate bundle IDs, home, port,
client layout, and fixture PTYs. The installed SlopZooka app and its session
service remained running throughout.

**Verdict:** actual native/iPhone video, readable text, phone aspect, and a source
aspect transition work. Both terminals accepted fresh input after a Direct helper
restart without a connection-method toggle. Native previews are **not ready to
enable by default**: motion, window controls, recovery, and truthful unavailable
state need work. This was not a complete pass of the prepared four-batch script.

The committed [evidence summary](evidence/2026-11-10-native-preview-device/summary.json)
retains selected timestamps, counters, and recovery events. Full private evidence
is under `/tmp/slz-preview-validation/run-IGpaRm`; the failed initial setup is
`run-TvpIXV`. Read **all** centralized log segments, not only `current.jsonl`.
No tokens, captured frames, unrelated titles, or user terminal contents are committed.

## Setup failure found and fixed

The real native provider became ready but timed out on short control commands.
Sampling showed it blocked in `NSConcreteFileHandle.readDataOfLength:`. A focused
reproduction wrote six bytes while keeping stdin open: no response; padding to
4096 bytes immediately released the read. This was a real implementation defect
missed by the earlier provider stand-in and codec tests, not a headset problem.

`WindowHost.swift` now reads `availableData`, keeping the existing bounded newline
parser and parent-EOF lifetime. The signed test helper was rebuilt, replaced in
the isolated bundle, and the bundle re-signed/verified before continuing. The new
real-helper regression checks fragmented short commands, coalesced commands, and
parent EOF without enumerating/capturing windows or prompting for permission.
It is included in the existing native media checks. After the slot, verification
passed again: the control regression, hardware H.264/socket suite, all 70 companion
tests, native state checks, terminal keyboard/WebKit checks, lint, types, formatting,
browser build/asset parity, and the full visionOS simulator build. Logs are
`/tmp/slz-preview-validation/{control-regression,native-video-postfix,final-*}.log`.

Capture enumeration then succeeded without a permission prompt. This establishes
capture under the observed launch chain, **not** first-install TCC attribution,
permission revocation, or the shipping bundle's permission UX.

The headset initially selected the existing companion on port 7777 despite the
test launch address argument. Selecting the other discovered companion worked;
the isolated listener was `192.168.0.29:64365`. Do not remove the user's working
companion to hide this selection issue. Make the test target explicit next time.

## Preview observations

| Check | Observation and status |
| --- | --- |
| Real native + Simulator streams | User confirmed both showed fresh nonce `6df25461`, moving markers, readable text, and correct phone shape. **Pass for this run.** |
| Source aspect change | Native fixture changed from wide to tall and headset preview followed. **Pass.** Simulator itself was not rotated. |
| Motion | User observed a periodic stutter with a reliable rhythm. The first two sender summaries averaged 22.64 and 22.80 offered video packets/sec, with 612 and 834 dropped offers respectively, against a 30 fps starting configuration. These are sender counters, not physical display FPS or latency. **Quality issue, cause unproven.** |
| Resize and Reload | User accidentally closed the preview while trying to resize because the bottom menu bar obscured the resize corner. **UX defect; scale preservation across Reload not established.** |
| Explicit close | Mac preview disappeared from the desired layout; Simulator remained visible and source/PTY processes survived. **Pass for isolation and persisted close.** |
| Remote reopen with launcher closed | User closed the launcher; operator re-added the observed Mac source through the layout API. User did not see the Mac preview return. **Not passed.** This is a server-authored layout/recovery observation, not proof that the manual Open action fails. |
| Covered sources | Operator covered the Mac, then advanced nonce to `81f85009`. User could not confirm both fresh views; the remaining preview displayed “Mac capture stopped reload to try again.” Server recorded `failed` at 23:20:04 after 1,054 frames. **Not passed; cause unproven.** The cover also risked obscuring the Mac reply UI; use a source-only cover next time. |
| Manual retry | A later viewer sent 1,017 frames before the Direct switch. This is evidence that capture resumed after the requested Reload, but not a separately confirmed visual recovery verdict. |
| Direct gating | On Direct, native preview stopped and displayed the correct “not supported on Direct to Mac yet” explanation. **Pass before headset restart.** |
| Launcher warning | User saw “Window recovery needs attention: Pair with this mac first” while the selected test Mac was authenticated and Direct worked. **Misleading state to investigate**, including the separately discovered, unpaired companion. |
| Headset restart | After an unexpected battery interruption, both terminals returned. The preview changed to indefinite “Reconnecting to your Mac…” on Direct instead of the useful unsupported-route explanation. **Observed state issue, with fixture identity caveat below.** |
| Lock/unlock and source loss | **Not run.** Deferred after the failed preview checks to avoid spending wearer time on an already uncertain baseline. |

## Direct recovery: functional pass, bounded idle recovery not established

The user was asked to close the launcher, confirmed readiness with both terminals
back, and later confirmed matching `final-a` / `final-b` ACKs in both terminals
without reopening the launcher or changing method. There is no independent
launcher-presence telemetry for that final step; preserve that evidentiary limit.

- The operator verified the helper's ownership chain before terminating PID
  `13389` at **23:28:22.304**. Only the isolated transport helper was interrupted.
- Replacement helper PID `22474` became ready at **23:28:23.407** (~1.10 seconds).
- Both terminal relay connections reopened on **Direct**, at **23:29:06.664** and
  **23:29:12.146**. No silent LAN fallback was observed.
- Browser A reported the old socket closed/retrying at **23:29:06.050** and attached
  at **23:29:06.683** (~633 ms). Browser B did so at **23:29:11.651** and
  **23:29:12.172** (~521 ms). These use each browser's own timestamp series.
- User observed a roughly 500 ms “lost connection” flash on focusing each window.
  Do not present the 44–50 seconds between helper termination and relay reopen as
  proven continuous visible outage, or the ~0.5-second reconnect as an unattended
  recovery SLA. Focus/visibility-dependent WebKit scheduling needs qualification.
- Both final input receipts came from the **original PTY PIDs 13397 and 13398**;
  the session-service identity stayed `c9b6dbb6-bd9c-4982-9d05-e7b5fd42c833`.
  No duplicate processes, manual method toggle, or launcher-driven repair was
  required for the final input checks.

This closes the narrow “can both terminals recover and accept input without a
method toggle?” question for this run. It does not establish fast recovery of
untouched/background windows, travel/no-LAN behavior, or Direct video.

## Test limitations and next work

The headset battery died during the session. Direct sockets closed at 23:25:48
and returned around 23:26:30; the exact onset of power/background effects relative
to the earlier preview failure is unknown. Do not attribute the capture failure
to occlusion alone without reproduction.

The rig also injected `companionClientID` as a launch argument. That argument is
an ephemeral UserDefaults override, not persistent preference setup. After the
autonomous headset restart, logs show a different client ID. Source inspection
confirms the initializer returns the existing argument value without persisting
it. This is a **fixture defect**, and makes post-restart layout/preview conclusions
inconclusive for production identity/persistence. It does not explain the earlier
pre-restart remote reopen failure. Next time, use the app's naturally persisted
client ID and learn it before seeding the layout; do not add a production bypass.

Before another headset slot:

1. Keep the real-helper regression in the normal checks. Improve the local rig's
   target selection, persistent client identity, source-only covering, and clean
   operator shutdown. The test companion, session service, source fixture, and
   Simulator stopped; the two idle operator shells required explicit interruption.
2. Reproduce the capture stop and rhythmic stutter locally with this signed stack.
   Record bounded stage/error/source-health summaries at termination, not per-frame
   logs or generic “failed” alone. Separate idle/occluded sources, frame-credit
   pressure, renderer suspension, and actual capture/encoder failure before tuning.
3. Fix the resize affordance and reproduce remote reopen through `WindowGateway`
   with a stable client ID, with the launcher both open and closed. Fix the
   misleading authentication and Direct-restoration messages at their owners.
4. Repeat only the failed visual/recovery checks on a charged headset, then the
   deferred lock/unlock/source-loss gate. Permission repair/revocation and provider
   restart/reselection remain separate qualification before enabling by default.

Cleanup verified the isolated HTTP and session-service sockets stopped. Only the
test headset process (PID 322, verified by its exact app-container URL) was
terminated. The user's installed Mac app PID 13544, HTTP PID 13547, and session
service PID 32460 were unchanged. Both PRs remain draft; previews remain opt-in.
