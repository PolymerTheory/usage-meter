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
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME"
fi
if [[ -d "$TARGET_APP" ]]; then
  rm -rf "$TARGET_APP"
fi
cp -R "$SOURCE_APP" "$TARGET_APP"

"$TARGET_APP/Contents/MacOS/$APP_NAME" --install-claude-hooks
# Install/refresh the LaunchAgent. This both starts the app now (via launchctl
# bootstrap/kickstart) and keeps it running: it relaunches at login and within
# seconds if it ever exits unexpectedly.
"$TARGET_APP/Contents/MacOS/$APP_NAME" --install-launch-agent

echo "Installed and launched via LaunchAgent: $TARGET_APP"
