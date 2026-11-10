# Mac codec benchmarks — November 8, 2026

**Decision:** retain hardware low-latency H.264 for the first production integration. Ordinary real-time HEVC earns one physical headset comparison; it is a credible alternative, not a demonstrated overall winner. The clearest optimization to try next is converting the simulator's JPEG frames to H.264 on the Mac, feeding the existing video receiver.

Keep one video path and a source adapter. These results do not justify a codec-selection framework, automatic codec switching, a new transport, or a separate persistence/control layer. The benchmark remains isolated from production sources.

## Evidence and reproduction

- [Runner, corpus and measurement definitions](../experiments/shared-window-probe/Benchmarks/README.md)
- [Raw results and machine/source manifest](evidence/2026-11-08-codec-benchmarks/results.json)
- [All 26 cases as CSV](evidence/2026-11-08-codec-benchmarks/results.csv)
- [Timestamped attempt/configuration journal](evidence/2026-11-08-codec-benchmarks/journal.jsonl)
- [Earlier physical Mac/Vision Pro findings](shared-window-live-results.md)

All **26 cases completed successfully**, with **7,620 measured frames encoded and locally decoded**, zero admission/encoder drops, no pending frames and no codec errors. Warmup frames are excluded. Four capability cases measured two seconds each; twenty-two performance cases measured six seconds after two seconds of warmup. This is a short comparative screen, not a long-running capacity or reliability qualification.

Machine: **Apple M4 Max, Mac16,6, 128 GiB**, macOS 26.5.2 (25F84), Xcode 26.3 (17C529), Swift 6.2.4, MacOSX26.2 SDK. Base commit: `b8e7cb18b9f97b8cfb8692b1cad97ef0bf0eb639`. Exact executed Swift/runner SHA-256 hashes are in the manifest. The four mode follow-ups reused the original executable. No desktop capture, simulator launch, permissions change, headset connection or network streaming occurred during the benchmark.

**Background load was substantial.** Other user workloads were left running. One-minute load averages at case start ranged from 20.17 to 110.53; load average is not CPU utilization. All recorded thermal states were nominal and low-power mode was off. Performance comparisons were sequential, not simultaneous, and follow-up load was lower than during the main matrix. Do not rank codecs by sub-millisecond differences or extrapolate power from process CPU. The repeated HEVC baseline's local p95 varied from 7.19 to 8.39 ms, illustrating the timing uncertainty.

## Results that inform the design

Tables report **actual encoded payload Mbps summed across streams**. The requested target is per encoder. The local p95 ends at a **Mac hardware decoder**, not a headset display; it is not interaction latency. Luma PSNR is an objective distortion diagnostic, with higher values indicating closer luma samples, not a readability score.

### Low-latency encoders

| Workload | Target per stream | H.264 payload Mbps | HEVC payload Mbps | H.264 local p95 ms | HEVC local p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Static UI, 1080p30 × 1 | 8 Mbps | 2.01 | 1.84 | 7.09 | 7.31 |
| Scrolling text, 1080p30 × 1 | 8 Mbps | 6.59 | 6.99 | 7.31 | 7.19 |
| Scrolling text, 1080p30 × 1 | 4 Mbps | 4.00 | 3.67 | 6.90 | 7.51 |
| Scrolling text, 1080p30 × 3 | 8 Mbps | 19.98 | 20.65 | 11.03 | 11.45 |
| Animated UI, 1080p30 × 1 | 8 Mbps | 2.39 | 2.20 | 7.35 | 7.25 |
| Animated UI, 1080p60 × 3 | 8 Mbps | 9.38 | 8.51 | 10.52 | 11.41 |

Both codecs handled three concurrent 1080p60 synthetic streams without measured drops. This says that these short, mostly UI-like workloads fit on this Mac, with a local decoder included. It does not establish three real 60 fps capture streams, headset decoder capacity or equivalent performance on other Macs.

Low-latency HEVC saved about 8–9% in the static/animated cases, but used more payload for 8 Mbps-target scrolling. In that scrolling case, sampled text luma PSNR was 54.77 dB for H.264 and 52.48 dB for HEVC. At the 4 Mbps target, it was 46.17 versus 46.30 dB. There is no consistent low-latency HEVC advantage here that warrants replacing the already exercised H.264 receiver.

Static cases still submit 30 identical frames per second and request a keyframe each second. Their 1.84–2.01 Mbps is not a prediction of idle production traffic: ScreenCaptureKit may deliver fewer unchanged frames, and keyframe policy affects cost.

### Ordinary real-time HEVC deserves a device comparison

The initial static capability check suggested better fidelity with ordinary HEVC. Four additional cases tested that mode instead of assuming the low-latency encoder was HEVC's best option. Both modes disabled reordering and requested real-time operation.

| Scrolling 1080p30, one stream | Actual Mbps | Encode p95 ms | Local p95 ms | Text luma PSNR dB |
| --- | ---: | ---: | ---: | ---: |
| H.264 low-latency, 4 Mbps target | 4.00 | 5.66 | 6.90 | 46.17 |
| HEVC low-latency, 4 Mbps target | 3.67 | 6.38 | 7.51 | 46.30 |
| HEVC ordinary real-time, 4 Mbps target | 3.16 | 14.38 | 16.22 | 50.53 |
| H.264 low-latency, 8 Mbps target | 6.59 | 5.85 | 7.31 | 54.77 |
| HEVC low-latency, 8 Mbps target | 6.99 | 6.22 | 7.19 | 52.48 |
| HEVC ordinary real-time, 8 Mbps target | 5.53 | 14.44 | 16.42 | 53.81 |

At the 4 Mbps target, ordinary HEVC used about **21% less payload than H.264** and improved this text-luma metric by 4.36 dB, with about 9.3 ms more local p95 delay. At the 8 Mbps target, it used about 16% less payload with a slightly lower text-luma score. These are equal-target comparisons, not a sweep to matched perceived quality.

Three scrolling ordinary-HEVC streams used 16.67 Mbps total, with 24.31 ms local p95, versus H.264's 19.98 Mbps and 11.03 ms. In the three-stream 60 fps animation case ordinary HEVC instead used **more** payload: 12.20 Mbps versus H.264's 9.38, with similar sampled text luma and 16.48 versus 10.52 ms local p95. Codec/mode benefits depend on the content; no universal bitrate or latency ranking follows.

The product choice can remain simple: start with the proven H.264 path, compare this one HEVC configuration on Vision, then choose a default based on actual text and interaction quality. Do not build live per-scene codec selection to exploit these short synthetic differences.

### JPEG fallback transcoding is promising

Synthetic portrait frames were 702×1520 at 15 fps, ImageIO JPEG quality 0.25, followed by a 4 Mbps video target. This approximates the dimensions/rate/quality of the earlier fallback; it is not actual WDA output.

| Path | Payload Mbps | Local p95 ms | Process CPU, one core = 100% | Text luma PSNR dB |
| --- | ---: | ---: | ---: | ---: |
| JPEG source payload at admitted frame rate | 14.65 | Not measured as a relay | Not measured as a relay | 28.47 |
| JPEG → H.264 low-latency → local decode | 3.89 | 16.35 | 8.21% | 28.39 |
| JPEG → HEVC low-latency → local decode | 3.93 | 15.86 | 7.47% | 28.72 |
| Raw → H.264 low-latency → local decode | 3.99 | 8.95 | 1.11% | 44.30 |
| Raw → HEVC low-latency → local decode | 3.88 | 8.94 | 1.11% | 42.30 |

H.264 reduced encoded payload by approximately **73%** versus forwarding those JPEG bytes. JPEG decoding/conversion added about 8 ms at p95 before video submission. The local roundtrip increase and higher process CPU make that cost visible. Source and decoded synthetic PNGs were inspected: their orientation/layout matched; small-text JPEG artifacts remained. A higher PSNR after compression can reflect smoothing and is not recovered detail.

This does not reduce the simulator's JPEG-generation work or its loopback traffic, recover JPEG detail, or create more source frames. The next implementation should decode once on the Mac, encode H.264, and use the existing video framing/receiver. Retain direct JPEG as a diagnostic during the comparison; its long-term need is a later decision. A live WDA-to-headset transcode and its locked recovery remain untested.

## Capability checks and limitations

| Requested codec/mode | Selected encoder ID | Result |
| --- | --- | --- |
| H.264 low-latency | `com.apple.videotoolbox.videoencoder.h264.rtvc` | Hardware-required create/encode/decode passed |
| H.264 ordinary real-time | `com.apple.videotoolbox.videoencoder.ave.avc` | Hardware-required create/encode/decode passed |
| HEVC low-latency | `com.apple.videotoolbox.videoencoder.hevc.rtvc` | Hardware-required create/encode/decode passed |
| HEVC ordinary real-time | `com.apple.videotoolbox.videoencoder.ave.hevc` | Hardware-required create/encode/decode passed |

Low-latency HEVC is supported on this tested machine/OS. Apple's older H.264-specific low-latency presentation should not be read as evidence that current HEVC cannot use that mode. This experiment does not establish support on every deployment target.

`AllowFrameReordering` read back false. The optional `MaxFrameDelayCount=0` setter returned **-12900, property not supported**, in all four combinations; no result assumes it was accepted. Ordinary encoders nevertheless read that value as zero, while low-latency encoders did not support its readback. Low-latency encoder hardware-property readback also returned -12900; hardware-required session creation succeeded, and all decoders reported hardware use. Unsupported introspection is distinct from software fallback. See Apple's [hardware requirement](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder) and [low-latency encoding discussion](https://developer.apple.com/videos/play/wwdc2021/10158/).

Other interpretation limits:

- Frames are synthetic: a sixty-frame cycle, shared at different phase offsets between streams. Motion is UI animation, not high-entropy video; portrait text can be clipped by the small fixture panes. Quality samples cover only stream zero, once a second.
- Luma PSNR omits chroma damage, even though small colored text matters. The pipeline uses 4:2:0. Headset visual inspection at useful window sizes remains essential.
- Timings start at actual preparation/submission. The software pacer's p95 wakeup lateness was roughly 7–10 ms and is logged separately. Capture, networking, rendering and human action-to-response time are absent.
- Payload Mbps excludes framing/TLS/IP overhead and is not measured network throughput. Average bitrate is a request, not a maximum.
- Process CPU across cases ranged from 0.69% to 8.70% of one core, including local decode. It excludes media-service CPU and hardware energy. Peak RSS ranged from 50.9 to 188.8 MiB and includes fixtures and retained sample buffers. Neither number estimates the production app's full cost.
- Short runs with nominal thermal state do not measure sustained thermal behavior, battery cost or recovery. Lock/unlock evidence remains the earlier live experiment; it was not repeated here.

## Test log and conclusions

| Phase, UTC | Work and outcome | Conclusion |
| --- | --- | --- |
| Preparation | Built a standalone optimized Swift fixture/codec executable and Python runner. Compilation corrections were made before the measured matrix. | No production build dependency or capture permission is needed for this comparison. |
| 17:03 onward | Four capability checks, followed by eighteen sequential, seeded-order cases. All 22 passed; 5,640 measured frames decoded. Repeated 8 Mbps scrolling baselines were retained. | Low-latency HEVC works here; its efficiency advantage is inconsistent. JPEG transcode is worth a live comparison. |
| Between phases | Repository checks ran after the main measurements. They did not intentionally overlap either timed phase. | Keep build load out of the controlled benchmark process; background user load remains recorded. |
| Follow-up, ending 17:13 | Four ordinary-HEVC cases added 1,980 measured frames, all passed. A console-summary field typo stopped the ad-hoc runner after saving its first successful result; the remaining three cases resumed without repeating or discarding a measurement. | Ordinary HEVC has a meaningful text-bandwidth/latency tradeoff. Preserve it as the single HEVC candidate. |
| Evidence audit | Reconciled requested, encoded and decoded counts; verified zero drops/pending/errors, hardware-decoder evidence, quality samples and executed source hashes across all 26 cases. Retained the complete journal including the runner correction. | The committed CSV/JSON and methodology support the conclusions; no failed measurement was hidden. |

The next device slot can be narrow: use one real simulator or browser view, compare existing H.264 against ordinary HEVC for text/scroll/input delay, then compare JPEG relay against JPEG→H.264 at the same source settings. Confirm the selected path with three independent surfaces and reconnect/lock recovery. Measure actual receiver presentation and total host/headset cost before claiming an end-to-end performance pass. Keep the current direct LAN transport fixed during these comparisons.

## Repository verification

| Check | November 8 result |
| --- | --- |
| All 26 codec cases and independent evidence audit | Passed |
| `pnpm test` | Passed, 43 companion tests |
| `pnpm test:vision-state` | Passed |
| `pnpm typecheck` | Passed |
| `pnpm format:check` | Passed |
| `pnpm build:harness` and generated-assets diff | Passed; generated assets unchanged |
| Full visionOS simulator build, unsigned, two build jobs | Passed |
| Probe Python CLI tests | Passed, six tests |
| Evidence counts/hardware/hash checks, local Markdown links/fences, Python syntax and artifact hygiene | Passed |
| `pnpm test:terminal-keyboard` | Failed twice: editing-key checks passed, then the WebKit viewport fixture timed out; the second attempt ran separately after benchmarks |

The WebKit timeout remains unresolved. The test script, fixture and production browser sources were unchanged by this work; the cause has not been established. It is not a codec measurement failure, and this report does not call the whole repository verification green. No further retries or unrelated production fixes were made. The benchmark runner, evidence and documentation are the only additions/changes.
