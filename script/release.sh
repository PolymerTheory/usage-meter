#!/usr/bin/env bash
# Create a distributable zip of UsageMeter.app for a GitHub release.
#
# Output: dist/UsageMeter.zip
#
# Usage:
#   ./script/release.sh
#   ./script/release.sh --publish v0.1.0
set -euo pipefail

APP_NAME="UsageMeter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
REPOSITORY="PolymerTheory/usage-meter"
PUBLISH=false
TAG=""

if [[ "${1:-}" == "--publish" ]]; then
  PUBLISH=true
  TAG="${2:?usage: ./script/release.sh --publish vX.Y.Z}"
fi

# Build release app bundle
"$ROOT_DIR/script/package_app.sh"

# Remove any previous zip
rm -f "$ZIP_PATH"

# Create zip from inside dist/ so the archive contains UsageMeter.app at
# its root (no extra parent directory when unzipped).
(cd "$DIST_DIR" && zip -r "$ZIP_PATH" "$APP_NAME.app" --exclude "*.DS_Store")

echo
echo "Release archive: $ZIP_PATH"

if [[ "$PUBLISH" == true ]]; then
  git -C "$ROOT_DIR" diff --quiet
  git -C "$ROOT_DIR" diff --cached --quiet
  git -C "$ROOT_DIR" push origin main
  gh release create "$TAG" "$ZIP_PATH#UsageMeter.zip" \
    --repo "$REPOSITORY" \
    --target main \
    --title "UsageMeter $TAG" \
    --generate-notes
  echo "Published: https://github.com/$REPOSITORY/releases/tag/$TAG"
else
  echo
  echo "Publish with:"
  echo "  ./script/release.sh --publish v0.1.0"
fi
