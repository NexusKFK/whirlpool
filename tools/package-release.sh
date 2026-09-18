#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(plutil -extract CFBundleShortVersionString raw Info.plist)
mkdir -p dist
if [ -d Pinwheel.app ]; then
    codesign --verify --deep --strict Pinwheel.app
    ditto -c -k --sequesterRsrc --keepParent Pinwheel.app "dist/Pinwheel-$version-macOS.zip"
fi
if [ -f dist/windows-x64/Pinwheel.exe ]; then
    cp README.md README.zh-CN.md LICENSE ATTRIBUTION.md docs/WINDOWS-TESTING.md dist/windows-x64/
    python3 - "$version" <<'PY'
from pathlib import Path
import sys, zipfile
folder = Path('dist/windows-x64')
with zipfile.ZipFile(f'dist/Pinwheel-{sys.argv[1]}-windows-x64-preview.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(folder.rglob('*')):
        if file.is_file(): archive.write(file, Path('Pinwheel') / file.relative_to(folder))
PY
fi
python3 - "$version" <<'PY'
from pathlib import Path
import hashlib, sys
root = Path('dist')
archives = sorted(root.glob(f'Pinwheel-{sys.argv[1]}-*.zip'))
(root / 'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in archives))
for p in archives: print(p)
PY
