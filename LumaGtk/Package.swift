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
            ],
            linkerSettings: [
                // Fedora's Swift 6.2 ships libswiftObservation.so with an unresolved
                // reference to swift::threading::fatal that no other shipped library
                // exports. Until upstream fixes the packaging, allow the dynamic
                // linker to defer the symbol — it's only ever called on a fatal
                // assertion path inside Observation.
                .unsafeFlags(["-Xlinker", "--allow-shlib-undefined"]),
            ]
        ),
    ]
)
