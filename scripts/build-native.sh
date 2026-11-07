#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${RELAY_APP_OUTPUT:-../Relay Shelf.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -whole-module-optimization native/*.swift \
  -o "$APP/Contents/MacOS/RelayShelf" \
  -framework AppKit -framework WebKit -framework PDFKit -framework Carbon -framework ServiceManagement
cp native/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"
rsync -a --delete dist/ "$APP/Contents/Resources/web/"
node scripts/license-notices.mjs "$APP/Contents/Resources/ThirdPartyNotices.txt"
if [ -f native/AppIcon.icns ]; then cp native/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
codesign --force --deep --sign - "$APP"
echo "Built $APP"
