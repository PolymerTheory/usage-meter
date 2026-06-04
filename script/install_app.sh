#!/usr/bin/env bash
# Build and install UsageMeter into ~/Applications.
#
# Usage:
#   ./script/install_app.sh           # release build (default)
#   ./script/install_app.sh --debug   # debug build
set -euo pipefail

APP_NAME="UsageMeter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"

"$ROOT_DIR/script/package_app.sh" "$@"

mkdir -p "$INSTALL_DIR"
if [[ -d "$TARGET_APP" ]]; then
  rm -rf "$TARGET_APP"
fi
cp -R "$SOURCE_APP" "$TARGET_APP"

echo "$TARGET_APP"
