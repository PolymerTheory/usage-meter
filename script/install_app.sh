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
#
# We must also *verify* the service is fully gone before copying. These builds
# are ad-hoc signed, so each rebuild has a different cdhash. If launchd still
# holds the old service registration when the new bundle drops in, macOS's
# launch-constraint check rejects every relaunch ("Launch Constraint Violation
# / OS_REASON_CODESIGNING") and eventually abandons the service — which is
# exactly how a hasty re-install wedged launchd once. Blocking here makes a
# back-to-back re-run safe.
LAUNCH_AGENT_LABEL="io.github.PolymerTheory.UsageMeter"
SERVICE_TARGET="gui/$(id -u)/$LAUNCH_AGENT_LABEL"
launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true

# Block until launchd no longer knows about the service (up to ~5s).
for _ in $(seq 1 20); do
  launchctl print "$SERVICE_TARGET" >/dev/null 2>&1 || break
  sleep 0.25
done

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

# Verify the managed instance actually came up and stays up. A silent
# constraint-kill would otherwise leave the user with no running app and no
# auto-restart, looking exactly like a crash.
INSTANCE_OK=false
for _ in 1 2 3 4 5 6 7 8; do
  sleep 0.5
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then INSTANCE_OK=true; break; fi
done

if [[ "$INSTANCE_OK" == true ]]; then
  echo "Installed and launched via LaunchAgent: $TARGET_APP"
else
  echo "WARNING: installed to $TARGET_APP but the managed instance did not come up." >&2
  echo "         This usually means launchd still held a stale registration." >&2
  echo "         Recover with: launchctl bootout $SERVICE_TARGET; \\" >&2
  echo "                       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist" >&2
  exit 1
fi
