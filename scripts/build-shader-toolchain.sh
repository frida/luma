#!/bin/sh
#
# Builds glslang and SPIRV-Cross into Vendor/shader-toolchain, which is what
# the runtime GLSL->MSL translation links against. Neither project builds
# under SwiftPM, and relying on whatever a machine happens to have installed
# means the build works here and nowhere else.
#
# Only Apple platforms need this: elsewhere OpenGL takes the GLSL as it stands.

set -eu

# Xcode exports its whole build environment into a scheme's pre-action, and
# cmake takes it literally: an SDK named "auto", and a deployment target for
# every platform at once. Start again with nothing but a path.
if [ -z "${LUMA_TOOLCHAIN_ENV:-}" ]; then
    LUMA_TOOLCHAIN_ENV=1
    export LUMA_TOOLCHAIN_ENV
    exec /usr/bin/env -i \
        LUMA_TOOLCHAIN_ENV=1 \
        PATH="$PATH" \
        HOME="$HOME" \
        "$0" "$@"
fi

GLSLANG_TAG=15.4.0
SPIRV_CROSS_TAG=vulkan-sdk-1.4.313.0

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/Vendor/shader-toolchain"
work="$root/build/shader-toolchain"
architectures="arm64;x86_64"
deployment=15.0

# The libraries are what the runtime translation links against; the binaries
# are what the build-time one runs.
if [ -f "$vendor/glslang/include/glslang/Include/glslang_c_interface.h" ] &&
   [ -f "$vendor/spirv-cross/lib/libspirv-cross-c.a" ] &&
   [ -x "$vendor/glslang/bin/glslang" ] &&
   [ -x "$vendor/spirv-cross/bin/spirv-cross" ]; then
    echo "shader toolchain already built in $vendor"
    exit 0
fi

fetch() {
    name=$1
    url=$2
    tag=$3
    if [ ! -d "$work/$name" ]; then
        mkdir -p "$work"
        git clone --depth 1 --branch "$tag" "$url" "$work/$name"
    fi
}

fetch glslang https://github.com/KhronosGroup/glslang.git "$GLSLANG_TAG"
fetch spirv-cross https://github.com/KhronosGroup/SPIRV-Cross.git "$SPIRV_CROSS_TAG"

echo "building glslang"
cmake -S "$work/glslang" -B "$work/glslang/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$vendor/glslang" \
    -DCMAKE_OSX_ARCHITECTURES="$architectures" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DGLSLANG_TESTS=OFF \
    -DENABLE_GLSLANG_BINARIES=ON \
    -DENABLE_OPT=OFF \
    -DBUILD_EXTERNAL=OFF
cmake --build "$work/glslang/build" --config Release --target install

echo "building spirv-cross"
cmake -S "$work/spirv-cross" -B "$work/spirv-cross/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$vendor/spirv-cross" \
    -DCMAKE_OSX_ARCHITECTURES="$architectures" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSPIRV_CROSS_SHARED=OFF \
    -DSPIRV_CROSS_STATIC=ON \
    -DSPIRV_CROSS_CLI=ON \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF
cmake --build "$work/spirv-cross/build" --config Release --target install

echo "shader toolchain built in $vendor"
