#!/bin/zsh
# build.sh — builds build/ProxyRouter.app
set -e
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ProxyRouter"

APP=build/ProxyRouter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProxyRouter"
# drop debug symbols so no local build paths end up inside the app
strip -S -x "$APP/Contents/MacOS/ProxyRouter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign -f -s - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with: open $APP   (or copy it to /Applications first)"
