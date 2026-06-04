#!/usr/bin/env bash
# Create a distributable zip of UsageMeter.app for a GitHub release.
#
# Output: dist/UsageMeter.zip
#
# Usage:
#   ./script/release.sh
set -euo pipefail

APP_NAME="UsageMeter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"

# Build release app bundle
"$ROOT_DIR/script/package_app.sh"

# Remove any previous zip
rm -f "$ZIP_PATH"

# Create zip from inside dist/ so the archive contains UsageMeter.app at
# its root (no extra parent directory when unzipped).
(cd "$DIST_DIR" && zip -r "$ZIP_PATH" "$APP_NAME.app" --exclude "*.DS_Store")

echo
echo "Release archive: $ZIP_PATH"
echo
echo "To publish a GitHub release:"
echo "  1. Push the current commit and tag it:"
echo "       git tag v0.1.0 && git push origin main --tags"
echo "  2. Go to https://github.com/YOUR_USERNAME/usage-meter/releases/new"
echo "  3. Select the tag, add release notes, and upload $ZIP_PATH"
echo
echo "Users can then install with:"
echo "  curl -fsSL https://github.com/YOUR_USERNAME/usage-meter/releases/latest/download/UsageMeter.zip -o /tmp/UsageMeter.zip"
echo "  unzip -o /tmp/UsageMeter.zip -d ~/Applications"
echo "  open ~/Applications/UsageMeter.app"
