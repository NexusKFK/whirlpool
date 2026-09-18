#!/bin/bash
# Builds a signed local application; failed builds leave the previous app intact.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release "$@"
bin_path=$(swift build -c release "$@" --show-bin-path)
stage=$(mktemp -d .build/package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/Pinwheel.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/pinwheel" "$app/Contents/MacOS/pinwheel"
cp Info.plist "$app/Contents/Info.plist"
cp icons/pinwheel.icns "$app/Contents/Resources/pinwheel.icns"
for doc in README.md README.zh-CN.md LICENSE ATTRIBUTION.md; do
    if [ -f "$doc" ]; then cp "$doc" "$app/Contents/Resources/"; fi
done
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
rm -rf Pinwheel.app
mv "$app" Pinwheel.app
echo 'Built Pinwheel.app'
