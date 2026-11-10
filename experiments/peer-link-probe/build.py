#!/usr/bin/env python3
"""Build/preflight only. Never changes network settings or deploys to a device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"


def run(args, name, timeout=300):
    with (BUILD / f"{name}.log").open("w") as log:
        result = subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        print((BUILD / f"{name}.log").read_text()[-6000:])
        raise SystemExit(f"{name} failed; full log: {BUILD / f'{name}.log'}")
    print(f"{name}: OK", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checks", action="store_true")
    parser.add_argument("--device", action="store_true", help="Build for physical visionOS, without deploying")
    parser.add_argument("--team", help="Development team for a signed device build")
    args = parser.parse_args()
    os.umask(0o077)
    BUILD.mkdir(mode=0o700, exist_ok=True)
    BUILD.chmod(0o700)
    config = BUILD / "connection.json"
    if not config.exists():
        # Per-experiment key material. Neither the private key nor bearer goes in git/logs.
        run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
             "-subj", "/CN=SlopZooka Link Probe", "-keyout", "build/key.pem", "-out", "build/cert.pem"], "certificate")
        run(["/usr/bin/openssl", "x509", "-in", "build/cert.pem", "-outform", "DER", "-out", "build/cert.der"], "der")
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", "build/key.pem", "-in", "build/cert.pem",
             "-out", "build/identity.p12", "-passout", "pass:probe-local-only", "-keypbe", "PBE-SHA1-3DES",
             "-certpbe", "PBE-SHA1-3DES"], "identity")
        config.write_text(json.dumps({"service": f"SlzLink-{secrets.token_hex(4)}", "token": secrets.token_hex(32),
                                     "fingerprint": hashlib.sha256((BUILD / "cert.der").read_bytes()).hexdigest()}))
    sources = ["Sources/Link.swift", "Sources/Host.swift", "Sources/Client.swift"]
    run(["xcrun", "swiftc", "-swift-version", "5", "-O", *sources, "Sources/CLI.swift", "-o", "build/link-probe"], "mac-build")
    if args.checks:
        run(["xcrun", "swiftc", "-swift-version", "5", *sources, "Sources/Checks.swift", "-o", "build/checks"], "checks-build")
        run(["build/checks", str(config)], "checks", 35)
        run(["build/link-probe", "selftest", str(config), "--condition", "loopback-not-radio"], "loopback", 40)
        rows = [json.loads(line) for line in (BUILD / "loopback.log").read_text().splitlines() if line.startswith("{")]
        phases = [row["result"] for row in rows if row.get("event") == "phase_result"]
        assert len(phases) == 4 and [row["targetMbps"] for row in phases] == [0, 8, 24, 8]
        assert all(row["rttSamples"] >= 5 for row in phases)
        assert all(row["receivedFrames"] == row["host"]["sent"] for row in phases)
        assert any(row.get("event") == "client_report" for row in rows)
        assert any(row.get("event") == "completed" and row.get("hostSaved") for row in rows)
        print("loopback evidence: four phases, payload counts, reconnect and host receipt verified", flush=True)
    run(["xcodegen", "generate", "--spec", "project.yml", "--project", "build"], "generate")
    destination = "generic/platform=visionOS" + ("" if args.device else " Simulator")
    signing = [f"DEVELOPMENT_TEAM={args.team}"] if args.device and args.team else ["CODE_SIGNING_ALLOWED=NO"]
    run(["xcodebuild", "-project", "build/PeerLinkProbe.xcodeproj", "-scheme", "PeerLinkViewer",
         "-configuration", "Debug", "-destination", destination, "-derivedDataPath", "build/DerivedData",
         "-jobs", "2", *signing, "build"], "viewer-device" if args.device else "viewer-simulator", 600)
    print("Prepared. No headset/radio test has run. Keep build/ private; it contains test credentials.")


if __name__ == "__main__":
    main()
