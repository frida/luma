#!/bin/bash
set -euo pipefail

OUTDIR="${1:-screenshots}"
APP="build/Luma.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$APP" ]; then
  echo "Build the app first: make" >&2
  exit 1
fi

open -a "$APP" --args --new-document
sleep 5

PID=$(pgrep -x Luma | head -1)
if [ -z "$PID" ]; then
  echo "Luma not running" >&2
  exit 1
fi

echo "Attached to Luma pid $PID" >&2
python3 "$SCRIPT_DIR/capture-screenshots.py" "$PID" "$OUTDIR"

kill "$PID" 2>/dev/null || true
