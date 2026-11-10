# Native preview integration: local results

Date: 2026-11-10. Branch: `feat/native-window-previews`, stacked on transport
PR #54 at `aa02dd9`. macOS 26.5.2 / Xcode 26.3 / Swift 6.2.4, Apple Silicon.

## What these checks establish

- 70 companion tests pass. New provider tests exercise fragmented bounded control
  replies, a 350 KB binary round trip through the fixed HTTP upgrade, permission
  and lock responses, source loss, helper termination, invalid protocol rejection,
  and rejecting a previous source ID after provider replacement. These use a
  disposable provider stand-in, not ScreenCaptureKit or real permission prompts.
- Native state checks pass, including manual native preview resolution through
  WindowGateway, source-only persistence, unavailable-source suppression, and
  disconnect versus explicit close. Existing late-response, launcher-independent
  recovery, and terminal lifetime checks remain green.
- Native media checks cover every split of a packet, coalesced packets, invalid
  sizes/versions/sequences, two-frame credit limits, independent slow/healthy
  viewers, forged ACK rejection, keyframe recovery, and format/inactivity changes.
- Real loopback NWConnections exercise fragmented HTTP upgrade plus binary frames,
  consumer ACKs, first-frame warmup exceeding two seconds with acknowledged waiting
  heartbeats, EOF, renderer suspension without ACKs, and malformed media blocked
  before rendering. The fixture deliberately admits only its authenticated peer
  while an unrelated HTTP probe connects concurrently.
- Hardware H.264 output passes the packet parser, reconstructs native compressed
  samples, and decodes through VideoToolbox into matching portrait/landscape pixel
  dimensions. Ten consecutive combined socket/codec runs pass after fixture repair.
  This establishes local encode/decode behavior, not headset display latency.
- Type checking, TypeScript/Swift lint, formatting, generated browser-asset parity,
  terminal keyboard/WebKit checks, visionOS simulator compilation, ad-hoc Mac app
  packaging, and packaged-app checks pass. The latter preserve PTY ownership across
  UI/HTTP restart and validate the signed bundle; they do not grant Screen Recording.

## Investigation log

The first repeated socket/codec batch passed 4/10. Instrumentation reproduced an
extra loopback connection replacing the fixture's active peer before its first ACK;
its bytes entered the ACK parser and produced `invalidPacket`. The fixture had one
shared candidate connection and was vulnerable to unrelated loopback traffic,
consistent with companion frontend discovery. It now isolates candidate handshakes,
requires a per-run token, and includes an explicit unauthenticated HTTP probe. The
subsequent 10/10 runs pass. This was a fixture defect, not evidence of H.264 failure.
The production capture listener already uses single-use private tickets per viewer.

A fresh worktree with an external Mac build destination also exposed staging under
a missing repository `build/` directory. Packaging now stages beside its destination,
which also keeps the final rename on the same filesystem. A native keyboard test's
explicit source list was updated for the route-owned preview payload dependency.
The packaged fixture now waits for successful HTTP health, since its private startup
status can arrive before the admission gate opens; an early health response previously
caused it to dereference a missing diagnostic path.

## Evidence locations on this Mac

| Evidence | Log |
| --- | --- |
| Companion regression suite | `/tmp/slz-native-final-tests.log` |
| Native state and media checks | `/tmp/slz-native-final-state.log` |
| Hardware/socket repeated pass | `/tmp/slz-native-media-final.log` |
| Original repeated failure | `/tmp/slz-native-media-repeat.log` |
| Instrumented fixture diagnosis | `/tmp/slz-video-fixture-diagnosis.log` |
| Native keyboard/WebKit checks | `/tmp/slz-native-keyboard.log` |
| Type/lint/format/parity | `/tmp/slz-native-final-{types,lint,format,parity}.log` |
| Full visionOS build | `/tmp/slz-native-preview-build.log` |
| Mac packaging / packaged checks | `/tmp/slz-native-packaging.log`, `/tmp/slz-native-packaged-tests.log` |

Temporary logs are local evidence, not durable artifacts. The tests and this summary
are committed. No captured frames, window titles, credentials, or unrelated project
files are checked in.

## Remaining gate

The signed test builds and operator smoke checks are now prepared in the
[short headset acceptance script](2026-11-10-native-preview-device-slot.md).
These preparation checks do not change the physical-validation status below.

The feature remains off by default. No new headset install, desktop lock, permission
prompt, or actual desktop capture was performed for this implementation. Final signed
permission attribution, physical phone-shaped sizing (including rotation/reload),
visual sharpness and motion, covered-window capture, multi-view hardware capacity,
channel recovery, and actual lock/unlock behavior require the focused device slot in
[the implementation plan](2026-11-10-native-preview-implementation.md#focused-device-gate).
Direct video is explicitly disabled. The prior transport PR also retains its short
physical two-terminal EOF-recovery confirmation before leaving draft.
