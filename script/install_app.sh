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

# Unload the LaunchAgent BEFORE replacing the bundle. Otherwise the agent's
# KeepAlive would relaunch the app the instant pkill stops it, and that
# relaunch racing the copy below corrupts the freshly-copied bundle.
LAUNCH_AGENT_LABEL="io.github.PolymerTheory.UsageMeter"
launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME"
fi
# Wait for the process to actually go away before copying.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
  sleep 0.3
done

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
