// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "luma",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "LumaCore", targets: ["LumaCore"]),
        .executable(name: "luma-bundle-compiler", targets: ["LumaBundleCompiler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/frida/frida-swift", branch: "main"),
        .package(url: "https://github.com/apple/swift-crypto", .upToNextMajor(from: "3.0.0")),
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/radareorg/SwiftyR2", branch: "main"),
    ],
    targets: [
        .target(
            name: "LumaCore",
            dependencies: [
                .product(name: "Frida", package: "frida-swift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftyR2", package: "SwiftyR2"),
            ],
            path: "Sources/LumaCore",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
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
    ]
)
