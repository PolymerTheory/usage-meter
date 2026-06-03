#!/usr/bin/env bash
set -euo pipefail

APP_NAME="UsageMeter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

if [[ ! -x "$APP_DIR/Contents/MacOS/$APP_NAME" ]]; then
  echo "$APP_NAME has not been built yet. Run ./script/build_and_run.sh --verify first." >&2
  exit 1
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME"
fi

/usr/bin/open -n "$APP_DIR"
