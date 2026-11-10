#!/usr/bin/env python3
"""Build only: no apps launched, devices booted, or privacy prompts requested."""
import argparse
import os
import plistlib
from pathlib import Path
import re
import subprocess
ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT/'build'

def run(command, name, timeout=600):
    with (BUILD/(name+'.log')).open('w') as log:
        subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=timeout)
    print(name+': OK',flush=True)

def main():
    p=argparse.ArgumentParser(); p.add_argument('--sign',action='store_true'); p.add_argument('--codec',action='store_true'); a=p.parse_args()
    BUILD.mkdir(exist_ok=True)
    run(['xcodegen','generate','--spec','project.yml','--project','build'],'generate',60)
    base=['xcodebuild','-project','build/SharedWindowProbe.xcodeproj','-configuration','Debug','-derivedDataPath','build/DerivedData','-jobs','2','CODE_SIGNING_ALLOWED=NO']
    for scheme,destination,action in [('ProbeHost','generic/platform=macOS','build'),('ProbeViewer','generic/platform=visionOS','build'),('ProbeChecks','generic/platform=macOS','build'),('ProbeFixture','generic/platform=iOS Simulator','build-for-testing')]:
        run(base+['-scheme',scheme,'-destination',destination,action],scheme)
    test_runs=list((BUILD/'DerivedData/Build/Products').glob('ProbeFixture_*.xctestrun'))
    if not test_runs or not any('ProbeFixtureTests' in str(plistlib.loads(path.read_bytes())) for path in test_runs):
        raise RuntimeError('Build succeeded without the fixture test target in xctestrun')
    run([str(BUILD/'DerivedData/Build/Products/Debug/ProbeChecks')]+(['--codec'] if a.codec else []),'checks',30)
    folder=BUILD/'run'; folder.mkdir(mode=0o700,exist_ok=True); folder.chmod(0o700)
    if not (folder/'identity.p12').exists():
        previous=os.umask(0o077)
        try:
            run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','30','-subj','/CN=SlopZooka Probe','-keyout',str(folder/'key.pem'),'-out',str(folder/'certificate.pem')],'certificate',30)
            run(['/usr/bin/openssl','x509','-in',str(folder/'certificate.pem'),'-outform','DER','-out',str(folder/'certificate.der')],'certificate-der',30)
            run(['/usr/bin/openssl','pkcs12','-export','-inkey',str(folder/'key.pem'),'-in',str(folder/'certificate.pem'),'-out',str(folder/'identity.p12'),'-passout','pass:probe-local-only','-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES'],'identity',30)
        finally: os.umask(previous)
    if a.sign:
        identity=os.environ.get('PROBE_SIGN_IDENTITY')
        if not identity:
            output=subprocess.check_output(['security','find-identity','-v','-p','codesigning'],text=True)
            match=re.search(r'([A-F0-9]{40}) "(?:Apple Development|Developer ID Application|Mac Developer):',output)
            if not match: raise SystemExit('Configure a signing certificate in Xcode, or set PROBE_SIGN_IDENTITY.')
            identity=match[1]
        app=str(BUILD/'DerivedData/Build/Products/Debug/ProbeHost.app')
        run(['codesign','--force','--deep','--sign',identity,app],'sign',60)
        run(['codesign','--verify','--deep','--strict',app],'verify-signature',30)
    print('Build complete. Vision hardware deployment still needs your team/device in Xcode.')
if __name__=='__main__': main()
