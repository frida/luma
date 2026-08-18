#!/bin/sh
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/Sources/LumaCore/Resources/MachineIcons"

for svg in "$root"/MachineIcons/*.svg; do
    name=$(basename "$svg" .svg)
    rsvg-convert -w 96 -h 96 -o "$out/$name.png" "$svg"
    echo "$name.png"
done
