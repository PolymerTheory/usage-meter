#!/usr/bin/env bash
set -euo pipefail

APP_NAME="UsageMeter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME"
fi

"$ROOT_DIR/script/package_app.sh"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

if [[ "${1:-}" == "--verify" ]]; then
  rm -f /tmp/UsageMeter-launch.log
  /usr/bin/open -n "$APP_DIR"
  sleep 3
  PID="$(pgrep -x "$APP_NAME" | head -n 1)"
  if [[ -z "$PID" ]]; then
    echo "$APP_NAME did not stay running" >&2
    exit 1
  fi
  if ! grep -q "configured status button" /tmp/UsageMeter-launch.log; then
    echo "$APP_NAME is running but did not confirm status item creation" >&2
    exit 1
  fi
  echo "$APP_NAME launched (pid $PID)"
else
  /usr/bin/open -n "$APP_DIR"
fi
