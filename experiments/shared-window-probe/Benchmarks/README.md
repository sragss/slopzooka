# Offline Mac codec benchmark

A standalone Swift executable and sequential Python runner compare hardware VideoToolbox encoding and local hardware decoding. They generate synthetic UI frames without screen capture, permissions, network listeners, app control, or a headset. Nothing is linked into the production apps.

The [November 8 results](../../../.plans/2026-11-08-mac-codec-benchmarks.md) include the full test journal, machine/configuration manifest, source hashes, and CSV/JSON measurements.

## Run

From the repository root, with Xcode selected:

```sh
python3 experiments/shared-window-probe/Benchmarks/run.py
```

This compiles `CodecBench.swift` with optimization, runs four capability checks, then eighteen cases in a fixed shuffled order. Each performance case has two seconds of warmup and six measured seconds. `--seconds 30` extends each measurement; `--warmup 5` extends warmup. Each child has a watchdog; runs are sequential. Avoid overlapping builds or other benchmarks, and retain the recorded load/thermal state when interpreting results.

Outputs go to ignored `build/codec-bench/<UTC timestamp>/` within the probe: `manifest.json`, `results.json`, `journal.jsonl`, per-case JSON/console logs and synthetic source/decoded PNGs. The runner selects low-latency mode when its capability check succeeds, otherwise ordinary real-time mode, and records the selected configuration. It never substitutes a software codec.

For a single case or a deliberate mode comparison:

```sh
mkdir -p experiments/shared-window-probe/build/codec-bench/manual
xcrun swiftc -O -parse-as-library -swift-version 5 \
  experiments/shared-window-probe/Benchmarks/CodecBench.swift \
  -o experiments/shared-window-probe/build/codec-bench/manual/CodecBench

experiments/shared-window-probe/build/codec-bench/manual/CodecBench \
  --codec hevc --mode realtime --pattern scroll \
  --width 1920 --height 1080 --fps 30 --streams 1 --mbps 4 \
  --input raw --warmup 2 --seconds 6 --images true \
  --output experiments/shared-window-probe/build/codec-bench/manual/hevc-scroll.json
```

The November 8 follow-up used the same executable as the main matrix, with `hevc/realtime`: scroll/30 fps/1 stream at 8 and 4 Mbps, scroll/30 fps/3 streams at 8 Mbps each, and motion/60 fps/3 streams at 8 Mbps each. These four adaptive follow-ups are recorded in the journal; they are not automatically added to every matrix run.

Supported choices are `h264|hevc`, `lowlatency|realtime`, `static|scroll|motion`, `raw|jpeg`, one to three streams, 1–60 fps, 1–20 Mbps per encoder, 0–5 warmup seconds and 1–30 measured seconds. Use the measured 1920×1080 or 702×1520 sizes; arbitrary tiny dimensions are not a supported fixture. JPEG quality is fixed at 0.25. Use distinct output paths to retain comparisons.

## What is measured

- The corpus is an offscreen CoreGraphics/CoreText UI with small Menlo text, white/dark panes and colored text. Static repeats one frame; scrolling and animation cycle through sixty frames. Concurrent streams share the immutable corpus at different offsets, with independent codec sessions.
- Source buffers are converted to NV12 4:2:0 video range before timing. Raw cases submit those buffers. JPEG cases decode precomputed ImageIO JPEGs and convert to NV12 for each submitted frame during timing.
- Hardware encoding and decoding are required. Both modes set real-time operation, disable frame reordering, request the average bitrate and one keyframe per second. Low-latency mode additionally requests Apple's low-latency rate-control encoder. Optional `MaxFrameDelayCount=0` support and property readbacks are logged, not assumed.
- Admission is bounded to three outstanding frames per stream, including decode. The JSON preserves requested/encoded/decoded counts, explicit drops, pending work, errors and operation status codes. Check all of these: an `ok` status alone does not assert zero admission drops.
- `encodeMS` measures submission to compressed-sample callback. `localRoundtripMS` measures actual input preparation through the Mac decoder callback, including JPEG preparation where applicable. It excludes source scheduling lateness, capture, transport and display. `scheduleLatenessMS` records pacer wakeup delay separately.
- `actualMbpsTotal` is compressed sample payload across all streams divided by the measured wall interval. It excludes transport overhead and is neither the requested bitrate nor a hard cap. FPS counts decoded frames over that interval.
- Process CPU uses user plus system CPU time, where 100% is one core. It includes the local decoder but excludes other media processes and hardware energy. Peak RSS includes precomputed fixtures and retained decoded samples; it is not encoder-only memory.
- Once per measured second, stream zero retains a decoded image for comparison with its exact source frame. Luma PSNR is reported for the full frame and a small light-background text region. It does not measure colored-text fidelity, perceived readability or headset quality. PNG output and quality calculations occur after timing.

No result here establishes ScreenCaptureKit cadence, real WDA capture behavior, wire throughput, Vision presentation latency, lock recovery, battery cost or sustained thermal capacity. Keep device acceptance separate, and promote a codec only after that narrower physical comparison.
