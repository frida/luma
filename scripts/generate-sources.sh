#!/bin/sh
set -eu

# Xcode enumerates a package target's sources when it loads the package graph,
# which is before any build phase or scheme pre-action runs. Generated sources
# that appear during a build are therefore missing from that build's LumaCore,
# so they have to be written before xcodebuild is invoked at all. Pass
# --require-existing where the build has already started, to say so plainly
# rather than let the compiler fail on the missing declarations.
require_existing=false
if [ "${1:-}" = "--require-existing" ]; then
    require_existing=true
fi

root=$(cd "$(dirname "$0")/.." && pwd)
agent_out="$root/Sources/LumaCore/Generated/LumaAgent.swift"

if $require_existing && [ ! -f "$agent_out" ]; then
    echo "error: generated sources are missing; run scripts/generate-sources.sh and build again" >&2
    exit 1
fi

# Xcode hands a scheme pre-action SDKROOT=auto, which swift cannot resolve.
unset SDKROOT

swift run --package-path "$root" LumaBundleCompiler \
    --config       "$root/Agent/bundle.json" \
    --project-root "$root" \
    --staging-dir  "$root/build/.agent-staging"

# Built through SwiftPM rather than as a target in the Xcode project, so it
# links the same shader toolchain the runtime translation does.
swift run --package-path "$root" LumaShaderCompiler \
    --shader-dir "$root/Shaders" \
    --swift-out  "$root/Sources/LumaCore/Generated/ShaderEffects.swift" \
    --metal-dir  "$root/Luma/Shaders/Generated"
