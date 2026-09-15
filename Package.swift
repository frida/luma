// swift-tools-version: 6.1

let lumaFridaDevkitLinkerSettings: [LinkerSetting] = {
    guard let devkit = ProcessInfo.processInfo.environment["LUMA_FRIDA_DEVKIT"], !devkit.isEmpty else { return [] }
    var flags = ["-L\(devkit)/lib", "-lfrida-core", "-lc++", "-lresolv", "-liconv", "-lbsm", "-lm"]
    for framework in ["Foundation", "CoreFoundation", "AppKit", "CoreServices", "IOKit", "Security", "Network", "SystemConfiguration"] {
        flags += ["-framework", framework]
    }
    return [.unsafeFlags(flags)]
}()


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
#elseif os(Windows)
let cLumaAudioSources = ["luma_audio_device.c"]
let cLumaAudioLinkerSettings: [LinkerSetting] = []
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

let cCompressionTargets: [Target] = [
    .systemLibrary(
        name: "CLzma",
        path: "Sources/CLzma",
        pkgConfig: "liblzma",
        providers: [
            .apt(["liblzma-dev"]),
            .yum(["xz-devel"]),
        ]
    ),
    .systemLibrary(
        name: "CZlib",
        path: "Sources/CZlib",
        pkgConfig: "zlib",
        providers: [
            .apt(["zlib1g-dev"]),
            .yum(["zlib-devel"]),
        ]
    ),
]
let lumaCoreCompressionDeps: [Target.Dependency] = ["CLzma", "CZlib"]
#else
let cSoupTargets: [Target] = []
let lumaCoreSoupDeps: [Target.Dependency] = []
let cCompressionTargets: [Target] = []
let lumaCoreCompressionDeps: [Target.Dependency] = []
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
            .product(name: "GRPCCore", package: "grpc-swift-2"),
            .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            "CLumaAudio",
            "CZstd",
        ] + lumaCoreSoupDeps + lumaCoreCompressionDeps + shaderTranslateDeps,
        path: "Sources/LumaCore",
        exclude: lumaCoreExcludes,
        resources: [
            .process("Resources/LumaPortal.pem"),
            .copy("Resources/MachineIcons"),
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
        name: "CZstd",
        path: "Sources/CZstd",
        publicHeadersPath: "include"
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
        name: "LumaEditorCheck",
        dependencies: ["LumaCore"],
        path: "Sources/LumaEditorCheck",
        swiftSettings: [
            .swiftLanguageMode(.v6),
        ]
    ),
    .executableTarget(
        name: "LumaEmulatorCheck",
        dependencies: [
            "LumaCore",
            .product(name: "Frida", package: "frida-swift"),
        ],
        path: "Sources/LumaEmulatorCheck",
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ],
        linkerSettings: lumaFridaDevkitLinkerSettings
    ),
    .executableTarget(
        name: "LumaShaderCompiler",
        dependencies: shaderTranslateDeps,
        path: "Sources/LumaShaderCompiler",
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ]
    ),
    .executableTarget(
        name: "LumaVMCheck",
        dependencies: [
            "LumaCore",
            .product(name: "Frida", package: "frida-swift"),
        ],
        path: "Sources/LumaVMCheck",
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ]
    ),
]

// Frida comes from the published bindings and the artifact they name. Work on
// frida-core itself is picked up by pointing FRIDA_SWIFT_ROOT at a checkout of
// the bindings beside it, with USE_SYSTEM_FRIDA set so they link what
// pkg-config finds. Being told rather than asking the filesystem is what the
// toolchain artifact does above, and for the same reason.
let fridaSwift: Package.Dependency = ProcessInfo.processInfo.environment["FRIDA_SWIFT_ROOT"]
    .map { Package.Dependency.package(path: $0) } ?? .package(
        url: "https://github.com/frida/frida-swift",
        branch: "main"
    )

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
        .executable(name: "LumaEditorCheck", targets: ["LumaEditorCheck"]),
        .executable(name: "LumaSynthCheck", targets: ["LumaSynthCheck"]),
    ],
    dependencies: [
        fridaSwift,
        .package(url: "https://github.com/apple/swift-crypto", .upToNextMajor(from: "3.0.0")),
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/radareorg/SwiftyR2", branch: "main"),
        .package(url: "https://github.com/frida/SwiftyPharo", branch: "main"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/apple/swift-protobuf", .upToNextMajor(from: "1.28.0")),
    ],
    targets: cSoupTargets + cCompressionTargets + shaderTranslateTargets + lumaTargets + lumaBundlePluginTargets
)
