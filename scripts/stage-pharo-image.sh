#!/bin/sh
set -eu

release="vm-20260811.3"

root=$(cd "$(dirname "$0")/.." && pwd)
staged="$root/Sources/LumaCore/Resources/pharo-image"
local="$root/../SwiftyPharo/artifacts/SwiftyPharo.image"
cache="$root/build/.pharo/$release"

if [ -f "$local" ]; then
    image="$local"
else
    image="$cache/SwiftyPharo.image"
    if [ ! -f "$image" ]; then
        echo "Fetching Pharo image $release"
        mkdir -p "$cache"
        curl -sSL \
            "https://github.com/frida/SwiftyPharo/releases/download/$release/SwiftyPharo.image.zip" \
            -o "$cache/image.zip"
        unzip -qo "$cache/image.zip" -d "$cache"
    fi
fi

mkdir -p "$staged"
cp "$image" "$staged/SwiftyPharo.image"
cp "${image%.image}.changes" "$staged/SwiftyPharo.changes"
