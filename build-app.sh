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
# ── Signing ──────────────────────────────────────────────────────────────────
# Default: ad-hoc (local use only; Gatekeeper warns on other machines).
# Distribution: set DEVELOPER_ID_APPLICATION to your "Developer ID Application"
# certificate name, e.g.
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
#   KEYCHAIN_PROFILE=whirlpool-notary ./build-app.sh
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    codesign --force --deep --sign "$DEVELOPER_ID_APPLICATION" \
             --options runtime --timestamp "$app"
    codesign --verify --deep --strict "$app"
else
    codesign --force --deep --sign - "$app"
    codesign --verify --deep --strict "$app"
fi

rm -rf Whirlpool.app
mv "$app" Whirlpool.app
echo 'Built Whirlpool.app'

# ── Notarization (optional; requires Apple Developer Program) ────────────────
# One-time: xcrun notarytool store-credentials KEYCHAIN_PROFILE \
#     --apple-id you@example.com --team-id TEAMID
if [ -n "${KEYCHAIN_PROFILE:-}" ] && [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    zip -qry Whirlpool-notary.zip Whirlpool.app
    xcrun notarytool submit Whirlpool-notary.zip --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple Whirlpool.app
    rm -f Whirlpool-notary.zip
    echo 'Notarized Whirlpool.app'
fi
