# Native preview: first headset acceptance slot (historical)

Superseded for the next slot by [hardening and retest](2026-11-10-native-preview-hardening.md).

Executed with mixed results; see the [physical report](2026-11-10-native-preview-device-results.md).
The script below preserves the pre-test plan. Before reuse, fix its ephemeral
client-ID override and full-display cover as described in that report.

Candidate: `8aaef647914f409a5d4ed30ad7f2d08d619d25fb`, draft
[PR #56](https://github.com/sragss/slopzooka/pull/56), including transport
[PR #54](https://github.com/sragss/slopzooka/pull/54). This is a prepared test,
**not a device pass**. Budget approximately 5–7 minutes of wearer interaction
after first-run permissions. Stop on a failed gate, retain evidence, and let the
wearer take the headset off while investigating; no repeated troubleshooting loop.

## Prepared and checked

- Certificate-signed physical visionOS build succeeded. Bundle:
  `/tmp/slz-preview-validation/vp/Build/Products/Debug-xros/SlopZooka.app`,
  ID `com.slopzooka.probe.nativepreview`, display **Slz Preview Test**.
- Certificate-signed Mac package succeeded. Staged package only is branded
  **Slz Preview Test**, ID `com.slopzooka.probe.nativepreview.mac`, at
  `/tmp/slz-preview-validation/mac/SlopZooka.app`. Both apps have team
  `6Z445J2X34`; deep/strict signature verification passed after branding.
  The capture helper is the packaged, certificate-signed production helper.
- Disposable AppKit fixture and iOS Simulator fixture compile and are signed.
  A dedicated iPhone 16e simulator is installed and initially booted headlessly:
  `761C24A5-F683-49C2-A87D-5899350E65D4` (**Slz Native Preview Validation**).
  No user's Simulator device is reused. The fixture was launched headlessly and
  its rendered `prep-ready` nonce was visually verified in a simulator screenshot.
  An initial URL-based update triggered an iOS confirmation dialog; the prepared
  fixture now reads an atomic file in its own sandbox, verified without a dialog.
  Simulator is shut down after preparation; live startup uses that same device.
- Local operator runner: `/tmp/slz-preview-validation/operate.mjs`.
  `node --check` and its `--smoke` mode pass against the packaged Node/runtime:
  health, private desktop status, normal pairing, two real PTYs, layout CAS,
  fresh input ACKs, and both terminal WebSocket replays. HTTP and the private
  session-service socket were independently confirmed stopped after cleanup.
  Evidence: `/tmp/slz-preview-validation/smoke-UMUdNF/operator.jsonl`.
- The implementation's broader checks remain recorded in
  [local results](2026-11-10-native-preview-results.md). No product code changed
  during this device preparation.

The signed Mac menu parent, capture permission attribution, ScreenCaptureKit
capture, and physical headset renderer are deliberately still live checks.
The headset test app has not been installed/launched during preparation.
No permission prompt, source-window cover, desktop lock, or live SlopZooka restart
has been performed. The isolated identity avoids replacing installed SlopZooka;
its permission approval does not grant the shipping bundle permission.

## Operator setup, before asking for visual verdicts

Run `node /tmp/slz-preview-validation/operate.mjs --live` in a persistent terminal.
It creates a fresh private home, free port, unique client/host identities, two
deterministic terminal fixtures, and visible native/iPhone fixtures. There is no
automatic cutoff. `stop` ends only owned test processes and the dedicated simulator;
it never kills the user's normal companion or session service.

1. `status` confirms both sessions running. `sources` reports capture readiness.
   If permission is missing, `permission` invokes the existing explicit repair
   action; `settings` opens the existing system-settings action. Have the user
   approve the actual named responsible app and record the name. Do not reset TCC
   or revoke the user's shipping app grant. Any required app restart invalidates
   the old source IDs: enumerate and select again.
2. `open` selects the exact observed fixture source and the sole matching
   dedicated Simulator source, validates each through the normal resolver, and
   adds them through the existing revision-checked layout API. It does not invent
   a second window registry or control path. Unexpected candidate counts fail.
3. `launch` installs/launches only **Slz Preview Test** on the paired physical
   headset, with test address and client ID preselected. `code` reads the current
   code just before entry. The user approves Local Network and pairs once through
   the ordinary UI. Do not reuse a code from an earlier message/run.

The runner temporarily observes only `SLZ_DESKTOP` messages on its own Node
process's private parent pipe to obtain current pairing code, owner PID, and
session socket. It uses a per-process preload, not a product API or bundle change.
Credential files stay mode 0600 under a private directory; never commit them.
Source lists are restricted to the two test fixtures. Production diagnostics
remain the central logs under the isolated home. No screen frames or raw user
input are collected. Terminal input is disposable fixture text only.

## Four wearer batches

| Batch | Operator action | Minimal wearer action and pass condition |
| --- | --- | --- |
| **1. Fresh video and geometry** | `pulse`; native `portrait` then `landscape`. Record the nonce/count. | Confirm both streams show the current nonce and moving marker, readable small text, and a phone-shaped Simulator window. Resize one preview, then **Reload Content**: retained scale and correct aspect, no persistent black view. Native aspect transitions must follow the source. |
| **2. Window independence** | With launcher closed, `pulse`; after the user closes the Mac preview, check the persisted close, then `open` to reopen it. `cover`, `pulse`, then `uncover`. | Close only the launcher and Mac preview when prompted. Simulator stays fresh; Mac preview reopens without the launcher. Confirm the new nonce while sources are covered on the Mac. No source app or terminal process restarted. |
| **3. Direct recovery** | Snapshot service/session IDs. After Direct is connected and launcher closed, `restart-helper` interrupts only the verified test transport helper. Wait for new helper ready + both terminal connections on Direct; `pulse` supplies a fresh ACK nonce. Save central ingress/reconnect logs, not just HTTP health. | From a terminal, reopen launcher, select **Direct to Mac**, verify both native previews become unavailable, then close launcher. After interruption, type a short value in **each** terminal and see its ACK without a toggle. Both recover independently. Open launcher and return to LAN; same preview windows restore fresh video. |
| **4. Lock and source loss** | Ask for a brief lock only in the agreed slot. Observe locked provider state. After unlock, `pulse`; then `close-source` and inspect catalog/session IDs. | Lock Mac while watching: images clear with a truthful unavailable state. Unlock and Reload both; confirm fresh nonce. Finally, Mac source loss shows unavailable while Simulator remains fresh. Done; headset may come off. |

Two device ACKs and the central logs are required for the Direct recovery verdict.
The runner's PTY receipt or a local WebSocket replay alone does not prove that the
headset received anything. Likewise, encoder sends and renderer enqueue ACKs do
not prove visual freshness; the wearer must see the nonce change. Record ambiguous
observations as inconclusive, never pass. Include session-service identity and PTY
PIDs before/after to detect duplicate process creation.

## Evidence and boundaries

Each live run gets `/tmp/slz-preview-validation/run-*/operator.jsonl`, private setup,
and the isolated home's centralized logs. `note <verdict>` records concise human
observations. Preserve timestamps, nonce/counter, source IDs, geometry, helper PID
and recovery time, per-terminal route/ACK, source/PTY survival, actual permission
owner, and any failure reason. Summarize results in the tracked results document;
temporary files themselves are not durable evidence. Do not publish credentials,
window titles from unrelated apps, raw inputs, or captured screen contents.

This slot qualifies the integrated two-preview LAN path and the outstanding
two-terminal Direct EOF recovery check. It does **not** qualify Direct video,
eight simultaneous encoders, locked-desktop fallback capture, travel/no-Wi-Fi,
sleep/wake, headset reinstall/room-placement persistence, or input/CUA ownership.
Native fixture aspect changes exercise geometry; actual Simulator rotation must
be recorded separately if not performed. Permission revocation/regrant and capture
provider restart/reselection remain follow-up checks before enabling by default;
do not expand this slot silently. Keep the feature opt-in and both PRs draft until
the applicable gates are resolved.
