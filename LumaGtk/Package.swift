// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LumaGtk",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/rhx/SwiftGtk", branch: "gtk4"),
    ],
    targets: [
        .executableTarget(
            name: "LumaGtk",
            dependencies: [
                .product(name: "LumaCore", package: "luma"),
                .product(name: "Gtk", package: "SwiftGtk"),
            ],
            path: "Sources/LumaGtk",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
