"""Copy documentation from the inspected installation into an ignored local cache."""

import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess


APP = Path('/Applications/ChatGPT.app')
VERSION = '26.1023.51421'
ROOT = APP / 'Contents/Resources/cua_node/lib/node_modules/@oai'
DEST = Path(__file__).resolve().parent / 'build/guidance' / VERSION


def main():
    version = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    if version != VERSION:
        raise SystemExit(f'Expected inspected app {VERSION}; found {version}. Review the new installation first.')
    # Keep vendor text local. Do not assume a caller's gitignore matches this repo.
    ignored = subprocess.run(['git', 'check-ignore', '-q', str(DEST)], cwd=Path(__file__).parent)
    if ignored.returncode != 0:
        raise SystemExit(f'Refusing to copy vendor documentation into a non-ignored location: {DEST}')
    files = {
        ROOT / 'cua-repl/README.md',
        ROOT / 'cua/docs/tinysky-alt-core-cua-repl-mac.md',
        ROOT / 'cua/docs/tinysky-alt-core-cua-repl-no-cua.md',
        ROOT / 'cua/docs/tinysky-alt-other-browser-apis.md',
        ROOT / 'cua/docs/tinysky-alt-confirmations.md',
        ROOT / 'sky/docs/sky-window-api.md',
    }
    files.update((ROOT / 'cua-repl/instructions').glob('*.md'))
    files.add(ROOT / 'cua-repl/instructions/banner.js')
    files.update((ROOT / 'cua-repl/instructions/macos').glob('*.md'))
    browser_docs = ROOT / 'browser-desktop/environment-docs/codex-app'
    files.update(p for p in browser_docs.rglob('*') if p.suffix in {'.md', '.json'})
    if not all(p.is_file() for p in files):
        raise SystemExit('The inspected documentation layout has changed; no files copied.')
    DEST.mkdir(parents=True, exist_ok=True, mode=0o700)
    entries = []
    for source in sorted(files):
        relative = source.relative_to(ROOT)
        data = source.read_bytes()
        target = DEST / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        entries.append({'path': str(relative), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    manifest = {
        'appVersion': version,
        'sourceRoot': str(ROOT),
        'purpose': 'Local research cache; use live MCP and first-use guidance when driving the runtime.',
        'files': entries,
    }
    (DEST / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'destination': str(DEST), 'files': len(entries), 'bytes': sum(e['bytes'] for e in entries)}))


if __name__ == '__main__':
    main()
