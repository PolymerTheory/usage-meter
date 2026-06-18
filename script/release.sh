#!/usr/bin/env bash
# Prepare a signed Sparkle update or publish the exact prepared artifact.
#
# Usage:
#   ./script/release.sh v0.2.0
#   ./script/release.sh --publish v0.2.0
set -euo pipefail

APP_NAME="UsageMeter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
UPDATES_DIR="$DIST_DIR/updates"
REPOSITORY="PolymerTheory/usage-meter"
PUBLISH=false

if [[ "${1:-}" == "--publish" ]]; then
  PUBLISH=true
  shift
fi
TAG="${1:?usage: ./script/release.sh [--publish] vX.Y.Z}"
VERSION="${TAG#v}"

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Release tag must use vX.Y.Z format" >&2
  exit 1
fi
BUILD_NUMBER="$((10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]}))"

GENERATE_APPCAST="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle/bin/generate_appcast' -type f -print -quit)"
SIGN_UPDATE="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle/bin/sign_update' -type f -print -quit)"
if [[ ! -x "$GENERATE_APPCAST" || ! -x "$SIGN_UPDATE" ]]; then
  echo "Sparkle release tools not found. Run 'swift package resolve' first." >&2
  exit 1
fi

if [[ "$PUBLISH" == true ]]; then
  git -C "$ROOT_DIR" diff --quiet -- . ':!appcast.xml'
  git -C "$ROOT_DIR" diff --cached --quiet

  if [[ ! -f "$ZIP_PATH" || ! -f "$ROOT_DIR/appcast.xml" ]]; then
    echo "Prepared archive/feed missing. Run './script/release.sh $TAG' first." >&2
    exit 1
  fi

  ARCHIVE_VERSION="$(unzip -p "$ZIP_PATH" "$APP_NAME.app/Contents/Info.plist" | plutil -extract CFBundleShortVersionString raw -o - -)"
  if [[ "$ARCHIVE_VERSION" != "$VERSION" ]]; then
    echo "Prepared archive is version $ARCHIVE_VERSION, not $VERSION" >&2
    exit 1
  fi

  SIGNATURE="$(xmllint --xpath "string(//item[*[local-name()='version']='$BUILD_NUMBER']/enclosure/@*[local-name()='edSignature'])" "$ROOT_DIR/appcast.xml")"
  if [[ -z "$SIGNATURE" ]]; then
    echo "No Sparkle signature found for build $BUILD_NUMBER in appcast.xml" >&2
    exit 1
  fi
  "$SIGN_UPDATE" --verify "$ZIP_PATH" "$SIGNATURE"

  gh auth status >/dev/null

  git -C "$ROOT_DIR" add appcast.xml
  if ! git -C "$ROOT_DIR" diff --cached --quiet; then
    git -C "$ROOT_DIR" commit -m "Publish $TAG update feed"
  fi
  git -C "$ROOT_DIR" push origin main
  gh release create "$TAG" "$ZIP_PATH#$APP_NAME.zip" \
    --repo "$REPOSITORY" \
    --target main \
    --title "UsageMeter $TAG" \
    --generate-notes
  echo "Published: https://github.com/$REPOSITORY/releases/tag/$TAG"
  exit 0
fi

USAGE_METER_VERSION="$VERSION" \
USAGE_METER_BUILD_NUMBER="$BUILD_NUMBER" \
  "$ROOT_DIR/script/package_app.sh"

rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

rm -rf "$UPDATES_DIR"
mkdir -p "$UPDATES_DIR"
cp "$ZIP_PATH" "$UPDATES_DIR/$APP_NAME.zip"
if [[ -f "$ROOT_DIR/appcast.xml" ]]; then
  cp "$ROOT_DIR/appcast.xml" "$UPDATES_DIR/appcast.xml"
fi

"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
  --link "https://github.com/$REPOSITORY" \
  --maximum-versions 5 \
  "$UPDATES_DIR"
cp "$UPDATES_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"

echo "Release archive: $ZIP_PATH"
echo "Sparkle feed: $ROOT_DIR/appcast.xml"
echo "Publish this exact signed artifact with:"
echo "  ./script/release.sh --publish $TAG"
