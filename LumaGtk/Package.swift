// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LumaGtk",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/rhx/gir2swift.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftLibXML.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGLib.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGModule.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGObject.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGIO.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftCairo.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftHarfBuzz.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftPango.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftPangoCairo.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGdkPixbuf.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGraphene.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftAtk.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGdk.git", branch: "gtk4"),
        .package(url: "https://github.com/rhx/SwiftGsk.git", branch: "main"),
        .package(url: "https://github.com/rhx/SwiftGtk.git", branch: "gtk4"),
    ],
    targets: [
        .target(
            name: "CWebKit",
            path: "Sources/CWebKit",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I/usr/include/webkitgtk-6.0",
                    "-I/usr/include/glib-2.0",
                    "-I/usr/lib64/glib-2.0/include",
                    "-I/usr/include/gtk-4.0",
                    "-I/usr/include/pango-1.0",
                    "-I/usr/include/harfbuzz",
                    "-I/usr/include/cairo",
                    "-I/usr/include/gdk-pixbuf-2.0",
                    "-I/usr/include/graphene-1.0",
                    "-I/usr/lib64/graphene-1.0/include",
                    "-I/usr/include/libsoup-3.0",
                    "-I/usr/include/sysprof-6",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("webkitgtk-6.0"),
                .linkedLibrary("javascriptcoregtk-6.0"),
            ]
        ),
        .executableTarget(
            name: "LumaGtk",
            dependencies: [
                .product(name: "LumaCore", package: "luma"),
                .product(name: "Gtk", package: "SwiftGtk"),
                "CWebKit",
            ],
            path: "Sources/LumaGtk",
            resources: [
                .copy("Resources/MonacoWeb"),
            ],
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
