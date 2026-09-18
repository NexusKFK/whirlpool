#!/bin/bash
# Builds a signed local application; failed builds leave the previous app intact.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release "$@"
bin_path=$(swift build -c release "$@" --show-bin-path)
stage=$(mktemp -d .build/package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/Whirlpool.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/whirlpool" "$app/Contents/MacOS/whirlpool"
cp Info.plist "$app/Contents/Info.plist"
cp icons/whirlpool.icns "$app/Contents/Resources/whirlpool.icns"
for doc in README.md README.zh-CN.md LICENSE ATTRIBUTION.md; do
    if [ -f "$doc" ]; then cp "$doc" "$app/Contents/Resources/"; fi
done
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
rm -rf Whirlpool.app
mv "$app" Whirlpool.app
echo 'Built Whirlpool.app'
