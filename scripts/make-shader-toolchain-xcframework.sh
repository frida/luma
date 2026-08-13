#!/bin/sh
#
# Packs the glslang and SPIRV-Cross build into one xcframework, so nothing
# downstream builds them: the manifest names the published artifact, and both
# the runtime translation and the build-time one link the same libraries.
#
# Prints the checksum the manifest needs.

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/Vendor/shader-toolchain"
artifacts="$root/artifacts"
staging="$root/build/xcframework"

"$root/scripts/build-shader-toolchain.sh"

rm -rf "$staging" "$artifacts/ShaderToolchain.xcframework" \
    "$artifacts/ShaderToolchain.xcframework.zip"
mkdir -p "$staging/headers" "$artifacts"

# One library per slice is all an xcframework carries, and the two projects
# make fifteen between them.
for slice in macos ios ios-simulator; do
    libtool -static -o "$staging/libShaderToolchain-$slice.a" \
        "$vendor/$slice"/glslang/lib/*.a \
        "$vendor/$slice"/spirv-cross/lib/*.a 2>/dev/null
done

# The headers are the same wherever the library came from, so the host slice's
# stand for every slice.
cp -R "$vendor/macos/glslang/include/glslang" "$staging/headers/"
cp -R "$vendor/macos/spirv-cross/include/spirv_cross" "$staging/headers/"
# spirv_cross_c.h is what the translation actually includes, and it expects
# to be found without a directory in front of it.
cp "$vendor/macos/spirv-cross/include/spirv_cross/spirv_cross_c.h" "$staging/headers/"
cp "$vendor/macos/spirv-cross/include/spirv_cross/spirv.h" "$staging/headers/"

xcodebuild -create-xcframework \
    -library "$staging/libShaderToolchain-macos.a" \
    -headers "$staging/headers" \
    -library "$staging/libShaderToolchain-ios.a" \
    -headers "$staging/headers" \
    -library "$staging/libShaderToolchain-ios-simulator.a" \
    -headers "$staging/headers" \
    -output "$artifacts/ShaderToolchain.xcframework"

(cd "$artifacts" && zip -qry ShaderToolchain.xcframework.zip ShaderToolchain.xcframework)

echo "ShaderToolchain.xcframework.zip"
echo "checksum: $(swift package --package-path "$root" compute-checksum \
    "$artifacts/ShaderToolchain.xcframework.zip")"
