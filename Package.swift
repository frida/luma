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
]

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

let package = Package(
    name: "luma",
    platforms: [
        .macOS(.v15),
        .iOS("26.0"),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "LumaCore", targets: ["LumaCore"]),
        .executable(name: "luma-bundle-compiler", targets: ["LumaBundleCompiler"]),
        .executable(name: "LumaBundleCompiler", targets: ["LumaBundleCompiler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/frida/frida-swift", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto", .upToNextMajor(from: "3.0.0")),
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/radareorg/SwiftyR2", branch: "main"),
    ],
    targets: cSoupTargets + [
        .target(
            name: "LumaCore",
            dependencies: [
                .product(name: "Frida", package: "frida-swift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftyR2", package: "SwiftyR2"),
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
    ] + lumaBundlePluginTargets
)
