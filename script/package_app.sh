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
# Default to the newest version in the published update feed, so a plain local
# build/install never claims to be older than what's released (the old fixed
# default, 0.2.0, made Sparkle offer a "downgrade" update).
LATEST_FEED_VERSION="$(grep -o '<sparkle:shortVersionString>[^<]*' "$ROOT_DIR/appcast.xml" 2>/dev/null | head -1 | sed 's/.*>//')"
VERSION="${USAGE_METER_VERSION:-${LATEST_FEED_VERSION:-0.0.0}}"
# Sparkle compares CFBundleVersion, not the version string. Derive it exactly as
# release.sh does (major*10000 + minor*100 + patch); a fixed default of 200 made
# every locally installed build look older than any release.
if [[ -z "${USAGE_METER_BUILD_NUMBER:-}" && "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  BUILD_NUMBER="$((10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]}))"
else
  BUILD_NUMBER="${USAGE_METER_BUILD_NUMBER:-1}"
fi

BUILD_CONFIG="release"
for arg in "$@"; do
  [[ "$arg" == "--debug" ]] && BUILD_CONFIG="debug"
done

cd "$ROOT_DIR"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Ask SwiftPM where products land instead of hard-coding it: Xcode 27 / Swift
# 6.4 moved them from .build/<triple>/release to .build/out/Products/Release, and
# builds every --arch into that SAME directory. So copy each slice aside right
# after building it (the next build overwrites it) and check its architecture.
SLICES_DIR="$(mktemp -d)"
trap 'rm -rf "$SLICES_DIR"' EXIT
if [[ "$BUILD_CONFIG" == "release" ]]; then
  for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --product "$PRODUCT"
    bin_dir="$(swift build -c release --arch "$arch" --show-bin-path)"
    cp "$bin_dir/$PRODUCT" "$SLICES_DIR/$PRODUCT-$arch"
    actual="$(/usr/bin/lipo -archs "$SLICES_DIR/$PRODUCT-$arch")"
    if [[ "$actual" != "$arch" ]]; then
      echo "error: expected a $arch slice but $bin_dir/$PRODUCT is '$actual'" >&2
      exit 1
    fi
  done
else
  swift build
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"
if [[ "$BUILD_CONFIG" == "release" ]]; then
  /usr/bin/lipo -create \
    "$SLICES_DIR/$PRODUCT-arm64" \
    "$SLICES_DIR/$PRODUCT-x86_64" \
    -output "$APP_DIR/Contents/MacOS/$APP_NAME"
else
  cp "$(swift build --show-bin-path)/$PRODUCT" "$APP_DIR/Contents/MacOS/$APP_NAME"
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
# App icon. Menu-bar managers (e.g. Bartender) display the app's icon for its
# status item, so without one UsageMeter shows up as a blank square.
# Regenerate with: python script/make_icon.py
cp "$ROOT_DIR/script/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>UsageMeter</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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
  <false/>
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
