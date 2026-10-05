#!/bin/bash
set -euo pipefail

OUTDIR="${1:-screenshots}"
BINARY=".build/debug/LumaGtk"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Run inside a headless Mutter/Wayland session with a fresh D-Bus
exec dbus-run-session -- bash -c '
  OUTDIR="$1"; BINARY="$2"; SCRIPT_DIR="$3"

  export GTK_A11Y=none
  export G_MESSAGES_DEBUG=""

  mutter --headless --virtual-monitor 1920x1080 --wayland 2>/dev/null &
  MUTTER_PID=$!
  sleep 2

  # Find the Wayland display mutter created
  for f in /run/user/$(id -u)/wayland-*; do
    case "$f" in *.lock) continue ;; esac
    bn=$(basename "$f")
    [[ "$bn" == "wayland-0" ]] && continue
    export WAYLAND_DISPLAY="$bn"
    break
  done
  echo "Using WAYLAND_DISPLAY=$WAYLAND_DISPLAY" >&2

  "$BINARY" 2>/dev/null &
  APP_PID=$!
  sleep 2

  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "App failed to start" >&2
    kill "$MUTTER_PID" 2>/dev/null
    exit 1
  fi

  python3 "$SCRIPT_DIR/capture-screenshots.py" "$APP_PID" "$OUTDIR"

  kill "$APP_PID" "$MUTTER_PID" 2>/dev/null
  wait 2>/dev/null
' -- "$OUTDIR" "$BINARY" "$SCRIPT_DIR" 2>/dev/null
