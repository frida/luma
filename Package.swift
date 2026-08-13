// swift-tools-version: 6.1

import Foundation
import PackageDescription

#if canImport(Darwin)
let manifestArgs = CommandLine.arguments
let manifestFileno = manifestArgs.firstIndex(of: "-fileno").flatMap { index -> String? in
    let valueIndex = manifestArgs.index(after: index)
    guard valueIndex < manifestArgs.endIndex else { return nil }
    return manifestArgs[valueIndex]
}
let usesXcodePackageResolution = manifestFileno != nil && manifestFileno != "4"
#else
let usesXcodePackageResolution = false
#endif
let lumaCoreExcludes = usesXcodePackageResolution ? [] : ["Generated"]
let lumaCorePlugins: [Target.PluginUsage] = usesXcodePackageResolution ? [] : [
    .plugin(name: "LumaBundlePlugin"),
    .plugin(name: "LumaShaderPlugin"),
]
let lumaBundlePluginTargets: [Target] = usesXcodePackageResolution ? [] : [
    .plugin(
        name: "LumaBundlePlugin",
        capability: .buildTool(),
        dependencies: [
            .target(name: "LumaBundleCompiler"),
        ],
        path: "Plugins/LumaBundlePlugin"
    ),
    .plugin(
        name: "LumaShaderPlugin",
        capability: .buildTool(),
        dependencies: [
            .target(name: "LumaShaderCompiler"),
        ],
        path: "Plugins/LumaShaderPlugin"
    ),
]

#if canImport(Darwin)
// Apple's mobile SDKs reach the audio session through AVFoundation, so the
// device unit has to be Objective-C there. Desktop follows suit rather than
// carry two behaviours.
let cLumaAudioSources = ["luma_audio_device.m"]
let cLumaAudioLinkerSettings: [LinkerSetting] = [
    .linkedFramework("CoreAudio"),
    .linkedFramework("AudioToolbox"),
    .linkedFramework("CoreFoundation"),
]
#else
let cLumaAudioSources = ["luma_audio_device.c"]
// miniaudio dlopens ALSA and PulseAudio, so neither is a link-time dependency.
let cLumaAudioLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("pthread"),
    .linkedLibrary("m"),
    .linkedLibrary("dl"),
]
#endif

#if !canImport(Darwin)
let cSoupTargets: [Target] = [
    .systemLibrary(
        name: "CSoup",
        path: "Sources/CSoup",
        pkgConfig: "libsoup-3.0",
        providers: [
            .apt(["libsoup-3.0-dev"]),
            .yum(["libsoup3-devel"]),
        ]
    )
]
let lumaCoreSoupDeps: [Target.Dependency] = ["CSoup"]
#else
let cSoupTargets: [Target] = []
let lumaCoreSoupDeps: [Target.Dependency] = []
#endif

// Runtime GLSL->MSL translation, so a shader written in a snippet reaches a
// Metal host with no build step, and the same libraries do it at build time.
// Only Apple platforms have one to reach: elsewhere OpenGL takes the GLSL as
// it stands, and neither the target nor the toolchain it needs is built.
//
// Neither project builds under SwiftPM, so CI makes them into an xcframework
// (see scripts/make-shader-toolchain-xcframework.sh) and this names it.
//
// A locally made one short-circuits the published artifact, the way
// SwiftyPharo honours PHARO_VM_ROOT: run that script and set
// SHADER_TOOLCHAIN_ROOT=artifacts/ShaderToolchain.xcframework, which SwiftPM
// wants relative to the package. Asking the filesystem rather than being told
// would not do -- a manifest is cached, so whichever answer it gave first
// would stick.
let shaderToolchainVersion = "2"
let shaderToolchainRoot = ProcessInfo.processInfo.environment["SHADER_TOOLCHAIN_ROOT"]

#if canImport(Darwin)
let shaderToolchainTarget: Target = shaderToolchainRoot.map {
    .binaryTarget(name: "ShaderToolchain", path: $0)
} ?? .binaryTarget(
    name: "ShaderToolchain",
    url: "https://github.com/frida/luma/releases/download/"
        + "shader-toolchain-\(shaderToolchainVersion)/ShaderToolchain.xcframework.zip",
    checksum: "721feadac2243501ac04141ee6bd579955fce573f78c78d220c970eac0b97211"
)
let shaderTranslateTargets: [Target] = [
    shaderToolchainTarget,
    .target(
        name: "CShaderTranslate",
        dependencies: ["ShaderToolchain"],
        path: "Sources/CShaderTranslate",
        publicHeadersPath: "include",
        linkerSettings: [.unsafeFlags(["-lc++"])]
    ),
]
let shaderTranslateDeps: [Target.Dependency] = ["CShaderTranslate"]
#else
let shaderTranslateTargets: [Target] = []
let shaderTranslateDeps: [Target.Dependency] = []
#endif


// Typed up front: left inline, the whole array and its four concatenations
// are one expression, and the type-checker gives up on it.
let lumaTargets: [Target] = [
    .target(
        name: "LumaCore",
        dependencies: [
            .product(name: "Frida", package: "frida-swift"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "SwiftyR2", package: "SwiftyR2"),
            .product(name: "SwiftyPharo", package: "SwiftyPharo"),
            "CLumaAudio",
        ] + lumaCoreSoupDeps + shaderTranslateDeps,
        path: "Sources/LumaCore",
        exclude: lumaCoreExcludes,
        resources: [
            .process("Resources/LumaPortal.pem"),
            // Staged by the build, and copied rather than processed so it
            // keeps the directory the runtime looks in.
            .copy("Resources/pharo-image"),
        ],
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ],
        plugins: lumaCorePlugins
    ),
    .executableTarget(
        name: "LumaBundleCompiler",
        dependencies: [
            .product(name: "Frida", package: "frida-swift"),
        ],
        path: "Sources/LumaBundleCompiler",
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ]
    ),

    .target(
        name: "CLumaAudio",
        path: "Sources/CLumaAudio",
        sources: cLumaAudioSources,
        publicHeadersPath: "include",
        linkerSettings: cLumaAudioLinkerSettings
    ),
    .executableTarget(
        name: "LumaSynthCheck",
        dependencies: ["LumaCore"],
        path: "Sources/LumaSynthCheck",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
        name: "LumaExampleCheck",
        dependencies: ["LumaCore"],
        path: "Sources/LumaExampleCheck",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    .executableTarget(
        name: "LumaShaderCompiler",
        dependencies: shaderTranslateDeps,
        path: "Sources/LumaShaderCompiler",
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ]
    ),
]

let package = Package(
    name: "luma",
    platforms: [
        .macOS(.v15),
        .iOS("26.0"),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "LumaCore", targets: ["LumaCore"]),
        .executable(name: "LumaBundleCompiler", targets: ["LumaBundleCompiler"]),
        .executable(name: "LumaShaderCompiler", targets: ["LumaShaderCompiler"]),
        .executable(name: "LumaExampleCheck", targets: ["LumaExampleCheck"]),
        .executable(name: "LumaSynthCheck", targets: ["LumaSynthCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/frida/frida-swift", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto", .upToNextMajor(from: "3.0.0")),
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/radareorg/SwiftyR2", branch: "main"),
        .package(url: "https://github.com/frida/SwiftyPharo", branch: "main"),
    ],
    targets: cSoupTargets + shaderTranslateTargets + lumaTargets + lumaBundlePluginTargets
)
