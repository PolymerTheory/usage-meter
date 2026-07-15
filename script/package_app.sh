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
VERSION="${USAGE_METER_VERSION:-0.2.0}"
BUILD_NUMBER="${USAGE_METER_BUILD_NUMBER:-200}"

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
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"
if [[ "$BUILD_CONFIG" == "release" ]]; then
  /usr/bin/lipo -create \
    "$ROOT_DIR/.build/arm64-apple-macosx/release/$PRODUCT" \
    "$ROOT_DIR/.build/x86_64-apple-macosx/release/$PRODUCT" \
    -output "$APP_DIR/Contents/MacOS/$APP_NAME"
else
  cp "$ROOT_DIR/.build/debug/$PRODUCT" "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -type d -print -quit 2>/dev/null)"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not found. Run 'swift package resolve' first." >&2
  exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"
SPARKLE_ROOT="${SPARKLE_FRAMEWORK%%/Sparkle.xcframework/*}"
if [[ ! -f "$SPARKLE_ROOT/LICENSE" ]]; then
  echo "Sparkle license was not found at $SPARKLE_ROOT/LICENSE" >&2
  exit 1
fi
cp "$SPARKLE_ROOT/LICENSE" "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>UsageMeter</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.PolymerTheory.UsageMeter</string>
  <key>CFBundleName</key>
  <string>UsageMeter</string>
  <key>CFBundleDisplayName</key>
  <string>Usage Meter</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>__VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__BUILD_NUMBER__</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/PolymerTheory/usage-meter/main/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>__SPARKLE_PUBLIC_KEY__</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>21600</integer>
</dict>
</plist>
PLIST

SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
if [[ -z "$SPARKLE_PUBLIC_KEY" && -f "$ROOT_DIR/.sparkle-public-key" ]]; then
  SPARKLE_PUBLIC_KEY="$(tr -d '\n' < "$ROOT_DIR/.sparkle-public-key")"
fi
if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "Missing Sparkle public key. Run Sparkle's generate_keys tool first." >&2
  exit 1
fi

/usr/bin/sed -i '' \
  -e "s/__VERSION__/$VERSION/g" \
  -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/g" \
  -e "s/__SPARKLE_PUBLIC_KEY__/$SPARKLE_PUBLIC_KEY/g" \
  "$APP_DIR/Contents/Info.plist"

# Ad-hoc signing gives the bundle a consistent local signature. The app is not
# notarized, so first launch still requires the documented macOS confirmation.
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
