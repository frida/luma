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
// Metal host with no build step. Found wherever the toolchain happens to live
// for now; shipping wants prebuilt libraries beside the Pharo VM's, since
// neither project builds under SwiftPM.
let shaderToolchainRoot = ["/opt/homebrew/opt", "/usr/local/opt", "/usr"].first {
    FileManager.default.fileExists(atPath: $0 + "/glslang/include/glslang/Include/glslang_c_interface.h")
}
let cShaderTranslateCSettings: [CSetting] = shaderToolchainRoot.map { root in
    [.unsafeFlags(["-I\(root)/glslang/include", "-I\(root)/spirv-cross/include"])]
} ?? []
let cShaderTranslateLinkerSettings: [LinkerSetting] = shaderToolchainRoot.map { root in
    [.unsafeFlags([
        "-L\(root)/glslang/lib", "-lglslang", "-lglslang-default-resource-limits", "-lSPIRV",
        "-L\(root)/spirv-cross/lib",
        "-lspirv-cross-c", "-lspirv-cross-msl", "-lspirv-cross-hlsl", "-lspirv-cross-cpp",
        "-lspirv-cross-reflect", "-lspirv-cross-util", "-lspirv-cross-glsl", "-lspirv-cross-core",
        "-lc++",
    ])]
} ?? []

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
    ],
    dependencies: [
        .package(url: "https://github.com/frida/frida-swift", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto", .upToNextMajor(from: "3.0.0")),
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/radareorg/SwiftyR2", branch: "main"),
        .package(url: "https://github.com/frida/SwiftyPharo", branch: "main"),
    ],
    targets: cSoupTargets + [
        .target(
            name: "LumaCore",
            dependencies: [
                .product(name: "Frida", package: "frida-swift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftyR2", package: "SwiftyR2"),
                .product(name: "SwiftyPharo", package: "SwiftyPharo"),
                "CLumaAudio",
                "CShaderTranslate",
            ] + lumaCoreSoupDeps,
            path: "Sources/LumaCore",
            exclude: lumaCoreExcludes,
            resources: [
                .process("Resources"),
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
            name: "CShaderTranslate",
            path: "Sources/CShaderTranslate",
            publicHeadersPath: "include",
            cSettings: cShaderTranslateCSettings,
            linkerSettings: cShaderTranslateLinkerSettings
        ),
        .target(
            name: "CLumaAudio",
            path: "Sources/CLumaAudio",
            sources: cLumaAudioSources,
            publicHeadersPath: "include",
            linkerSettings: cLumaAudioLinkerSettings
        ),
        .executableTarget(
            name: "LumaShaderCompiler",
            path: "Sources/LumaShaderCompiler",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ] + lumaBundlePluginTargets
)
