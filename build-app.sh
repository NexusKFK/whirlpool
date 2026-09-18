#!/bin/bash
# Builds Pinwheel.app — ad-hoc 签名后可放应用程序/登录项。
# CLI 入口同一个二进制: pinwheel --send …
set -e

APP="Pinwheel.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swift build -c release 2>&1

cp .build/release/pinwheel "$CONTENTS/MacOS/pinwheel"
cp Info.plist "$CONTENTS/Info.plist"
cp icons/pinwheel.icns "$CONTENTS/Resources/pinwheel.icns"

# Ad-hoc sign — required for URL scheme registration
codesign --force --deep --sign - "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "→ $APP"
echo ""
echo "Symlink CLI: ln -sf \"\$(pwd)//$APP/Contents/MacOS/pinwheel\" ~/bin/pinwheel"
