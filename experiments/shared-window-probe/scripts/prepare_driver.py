#!/usr/bin/env python3
"""Download pinned local dependencies and build WDA; does not start Appium or a simulator."""
import json
import os
from pathlib import Path
import subprocess
from probe import ROOT

def main():
    build=ROOT/'build'; build.mkdir(exist_ok=True)
    with (build/'npm-prepare.log').open('w') as log:
        subprocess.run(['npm','ci','--ignore-scripts','--no-audit','--no-fund'],cwd=ROOT/'tooling',stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
    wda=ROOT/'tooling/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent'
    if not wda.exists(): wda=ROOT/'tooling/node_modules/appium-webdriveragent'
    if not (wda/'WebDriverAgent.xcodeproj').exists(): raise RuntimeError('Expected local WDA project is missing')
    with (build/'wda-build.log').open('w') as log:
        subprocess.run(['xcodebuild','-project',str(wda/'WebDriverAgent.xcodeproj'),'-scheme','WebDriverAgentRunner',
                        '-destination','generic/platform=iOS Simulator','-derivedDataPath',str(build/'wda-derived'),
                        '-jobs','2','CODE_SIGNING_ALLOWED=NO','build-for-testing'],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
    versions={name:json.loads((ROOT/'tooling/node_modules'/name/'package.json').read_text())['version'] for name in ['appium','appium-xcuitest-driver']}
    versions['appium-webdriveragent']=json.loads((wda/'package.json').read_text())['version']
    (build/'driver-versions.json').write_text(json.dumps(versions,indent=2))
    print(json.dumps({'prepared':versions,'runtime':'not launched'},indent=2))

if __name__=='__main__': main()
