#!/usr/bin/env python3
"""Sequential, offline VideoToolbox measurements; no GUI, capture, or simulator access."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(__file__).with_name('CodecBench.swift')
BUILD = ROOT / 'build' / 'codec-bench'


def output(args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=6)
    parser.add_argument('--warmup', type=int, default=2)
    args = parser.parse_args()
    assert 1 <= args.seconds <= 30 and 0 <= args.warmup <= 5
    BUILD.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    folder = BUILD / stamp
    folder.mkdir()
    binary = folder / 'CodecBench'
    compile_args = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '5', str(SOURCE), '-o', str(binary)]
    with (folder / 'compile.log').open('w') as log:
        subprocess.run(compile_args, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    manifest = dict(schema=1, startedAt=stamp, sourceSHA256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                    runnerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    baseCommit=output(['git', 'rev-parse', 'HEAD']),
                    macOS=output(['sw_vers']), hardwareModel=output(['sysctl', '-n', 'hw.model']),
                    cpu=output(['sysctl', '-n', 'machdep.cpu.brand_string']),
                    memoryBytes=int(output(['sysctl', '-n', 'hw.memsize'])),
                    xcode=output(['xcodebuild', '-version']), compiler=output(['xcrun', 'swiftc', '--version']),
                    orderSeed=8, warmupSeconds=args.warmup, measurementSeconds=args.seconds,
                    caveats=['Synthetic 60-frame cyclic corpus; static repeats one frame.',
                             'No ScreenCaptureKit, transport, Vision Pro, or system power measurement.',
                             'Mac hardware decode included in local roundtrip and process CPU.',
                             'Process CPU excludes system media services and does not measure hardware energy.',
                             'Peak memory includes precomputed fixtures; not incremental encoder memory.',
                             'Text luma PSNR is a diagnostic, not a perceptual readability verdict.',
                             'JPEG inputs use ImageIO quality 0.25, not actual WDA captures.',
                             'Other user workloads were not stopped; load/thermal state recorded.'])
    (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print('RESULT DIRECTORY:', folder, flush=True)
    results = []
    def journal(event):
        with (folder / 'journal.jsonl').open('a') as log:
            log.write(json.dumps(dict(at=dt.datetime.now(dt.timezone.utc).isoformat(), **event))+'\n')
    def run(name, config):
        path = folder / (name+'.json')
        cmd = [str(binary), '--output', str(path)]
        for key, value in config.items():
            cmd += ['--'+key, str(value).lower() if isinstance(value, bool) else str(value)]
        journal(dict(event='start', case=name, configuration=config))
        started = time.monotonic()
        try:
            with (folder / (name+'.log')).open('w') as log:
                process = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=args.seconds+args.warmup+30)
            result = json.loads(path.read_text()) if path.exists() else dict(status='error', error='No result document')
            result['exitCode'] = process.returncode
        except subprocess.TimeoutExpired:
            result = dict(status='error', error='Owned benchmark exceeded per-case watchdog', exitCode=None)
        result['case'] = name
        result['caseWallSeconds'] = time.monotonic()-started
        results.append(result)
        (folder/'results.json').write_text(json.dumps(dict(manifest=manifest, cases=results), indent=2)+'\n')
        journal(dict(event='finish', case=name, status=result.get('status'), exitCode=result.get('exitCode')))
        if result.get('status') == 'ok':
            print(f"{name}: {result['actualMbpsTotal']:.2f} Mbps; encode p95 {result['encodeMS']['p95']:.2f} ms; "
                  f"local roundtrip p95 {result['localRoundtripMS']['p95']:.2f} ms; "
                  f"{result['completedFPSPerStream']:.1f} fps/stream; drops "
                  f"{result['admissionDrops'] + result['encoderDrops']}", flush=True)
        else:
            print(name+': '+str(result.get('error', result.get('errors'))), flush=True)
        return result

    modes = {}
    for codec in ['h264', 'hevc']:
        for mode in ['lowlatency', 'realtime']:
            result = run('cap-'+codec+'-'+mode, dict(codec=codec, mode=mode, pattern='static', warmup=1, seconds=2))
            if result.get('status') == 'ok' and codec not in modes:
                modes[codec] = mode
    if set(modes) != {'h264', 'hevc'}:
        print('A codec is unavailable; results retained. Do not silently substitute software encoding.', flush=True)
        return 1
    cases = []
    for codec, mode in modes.items():
        base = dict(codec=codec, mode=mode, warmup=args.warmup, seconds=args.seconds, images=True)
        for pattern in ['static', 'scroll', 'motion']:
            cases.append((codec+'-'+pattern+'-1080p30-1x-8m', dict(base, pattern=pattern)))
        cases += [
            (codec+'-scroll-1080p30-3x-8m', dict(base, pattern='scroll', streams=3)),
            (codec+'-motion-1080p60-3x-8m', dict(base, pattern='motion', fps=60, streams=3)),
            (codec+'-scroll-1080p30-1x-4m', dict(base, pattern='scroll', mbps=4)),
            (codec+'-scroll-1080p30-1x-8m-repeat', dict(base, pattern='scroll')),
        ]
        for source in ['raw', 'jpeg']:
            cases.append((codec+'-scroll-portrait15-1x-4m-'+source,
                          dict(base, pattern='scroll', width=702, height=1520, fps=15, mbps=4, input=source)))
    random.Random(8).shuffle(cases)
    for name, config in cases:
        run(name, config)
    journal(dict(event='complete', count=len(results)))
    print('COMPLETE:', folder, flush=True)
    return int(any(c.get('status') != 'ok' for c in results if not c['case'].startswith('cap-')))


if __name__ == '__main__':
    sys.exit(main())
