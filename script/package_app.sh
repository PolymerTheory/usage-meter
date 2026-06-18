#!/usr/bin/env bash
# Build UsageMeter.app and place it in dist/.
#
# Usage:
#   ./script/package_app.sh           # release build (default)
#   ./script/package_app.sh --debug   # debug build
set -euo pipefail

APP_NAME="UsageMeter"
PRODUCT="UsageMeter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

BUILD_CONFIG="release"
for arg in "$@"; do
  [[ "$arg" == "--debug" ]] && BUILD_CONFIG="debug"
done

cd "$ROOT_DIR"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [[ "$BUILD_CONFIG" == "release" ]]; then
  swift build -c release --arch arm64 --product "$PRODUCT"
  swift build -c release --arch x86_64 --product "$PRODUCT"
else
  swift build
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
if [[ "$BUILD_CONFIG" == "release" ]]; then
  /usr/bin/lipo -create \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/$PRODUCT" \
    "$ROOT_DIR/.build/x86_64-apple-macosx/release/$PRODUCT" \
    -output "$APP_DIR/Contents/MacOS/$APP_NAME"
else
  cp "$ROOT_DIR/.build/debug/$PRODUCT" "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>UsageMeter</string>
  <key>CFBundleIdentifier</key>
  <string>local.usagemeter.prototype</string>
  <key>CFBundleName</key>
  <string>UsageMeter</string>
  <key>CFBundleDisplayName</key>
  <string>Usage Meter</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signing gives the bundle a consistent local signature. The app is not
# notarized, so first launch still requires the documented macOS confirmation.
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
