#!/bin/sh
#
# Builds glslang and SPIRV-Cross into Vendor/shader-toolchain, which is what
# the runtime GLSL->MSL translation links against. Neither project builds
# under SwiftPM, and relying on whatever a machine happens to have installed
# means the build works here and nowhere else.
#
# One tree per slice, because the runtime translation ships wherever the app
# does: macOS, the device and the simulator. Only the desktop slice carries
# the binaries, which are what the build-time translation runs.
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

fetch() {
    name=$1
    url=$2
    tag=$3
    if [ ! -d "$work/$name" ]; then
        mkdir -p "$work"
        git clone --depth 1 --branch "$tag" "$url" "$work/$name"
    fi
}

# The libraries are what the runtime translation links against; the binaries
# are what the build-time one runs, so only the host slice builds them.
build_slice() {
    slice=$1
    sdk=$2
    architectures=$3
    deployment=$4
    binaries=$5

    prefix="$vendor/$slice"
    if [ -f "$prefix/glslang/include/glslang/Include/glslang_c_interface.h" ] &&
       [ -f "$prefix/spirv-cross/lib/libspirv-cross-c.a" ] &&
       { [ "$binaries" = OFF ] ||
         { [ -x "$prefix/glslang/bin/glslang" ] && [ -x "$prefix/spirv-cross/bin/spirv-cross" ]; }; }; then
        echo "shader toolchain already built in $prefix"
        return
    fi

    # iOS is a cross build, so cmake is told the system outright rather than
    # left to read the sysroot: left to itself it would try to run what it
    # just built to answer its own configure checks.
    system=""
    if [ "$sdk" != macosx ]; then
        system="-DCMAKE_SYSTEM_NAME=iOS"
    fi

    echo "building glslang for $slice"
    cmake -S "$work/glslang" -B "$work/glslang/build-$slice" \
        $system \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix/glslang" \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES="$architectures" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DGLSLANG_TESTS=OFF \
        -DENABLE_GLSLANG_BINARIES="$binaries" \
        -DENABLE_OPT=OFF \
        -DBUILD_EXTERNAL=OFF
    cmake --build "$work/glslang/build-$slice" --config Release --target install

    echo "building spirv-cross for $slice"
    cmake -S "$work/spirv-cross" -B "$work/spirv-cross/build-$slice" \
        $system \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix/spirv-cross" \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES="$architectures" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DSPIRV_CROSS_SHARED=OFF \
        -DSPIRV_CROSS_STATIC=ON \
        -DSPIRV_CROSS_CLI="$binaries" \
        -DSPIRV_CROSS_ENABLE_TESTS=OFF
    cmake --build "$work/spirv-cross/build-$slice" --config Release --target install
}

fetch glslang https://github.com/KhronosGroup/glslang.git "$GLSLANG_TAG"
fetch spirv-cross https://github.com/KhronosGroup/SPIRV-Cross.git "$SPIRV_CROSS_TAG"

build_slice macos             macosx           "arm64;x86_64" 15.0 ON
build_slice ios               iphoneos         arm64          26.0 OFF
build_slice ios-simulator     iphonesimulator  arm64          26.0 OFF

echo "shader toolchain built in $vendor"
