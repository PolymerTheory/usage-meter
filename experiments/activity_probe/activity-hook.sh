#!/bin/sh
set -eu

provider="${1:-}"
state="${2:-}"
event="${3:-unknown}"

case "$provider" in
  codex|claude) ;;
  *)
    echo "usage: activity-hook.sh codex|claude busy|idle [event]" >&2
    exit 2
    ;;
esac

case "$state" in
  busy|idle) ;;
  *)
    echo "usage: activity-hook.sh codex|claude busy|idle [event]" >&2
    exit 2
    ;;
esac

dir="$HOME/Library/Application Support/UsageMeter/activity"
mkdir -p "$dir"
file="$dir/$provider.json"
tmp="$file.$$"

timestamp="$(date +%s)"

# Keep this deliberately minimal: no prompt text, no transcript, no tool args.
cat > "$tmp" <<EOF
{"provider":"$provider","state":"$state","event":"$event","timestamp":$timestamp}
EOF
mv "$tmp" "$file"
