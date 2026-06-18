#!/bin/sh
set -eu

cd "$(dirname "$0")"

build_dir=".build"
app_dir="$build_dir/ActivityProbe.app"
macos_dir="$app_dir/Contents/MacOS"

mkdir -p "$macos_dir"
swiftc ActivityProbe.swift -o "$macos_dir/ActivityProbe"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ActivityProbe</string>
  <key>CFBundleIdentifier</key>
  <string>local.usage-meter.activity-probe</string>
  <key>CFBundleName</key>
  <string>ActivityProbe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/open -n "$app_dir"
