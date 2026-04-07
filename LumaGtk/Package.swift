// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LumaGtk",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: ".."),
        .package(name: "gir2swift", path: "../../swift-gtk-fork/gir2swift"),
        .package(name: "SwiftLibXML", path: "../../swift-gtk-fork/SwiftLibXML"),
        .package(name: "SwiftGLib", path: "../../swift-gtk-fork/SwiftGLib"),
        .package(name: "SwiftGModule", path: "../../swift-gtk-fork/SwiftGModule"),
        .package(name: "SwiftGObject", path: "../../swift-gtk-fork/SwiftGObject"),
        .package(name: "SwiftGIO", path: "../../swift-gtk-fork/SwiftGIO"),
        .package(name: "SwiftCairo", path: "../../swift-gtk-fork/SwiftCairo"),
        .package(name: "SwiftHarfBuzz", path: "../../swift-gtk-fork/SwiftHarfBuzz"),
        .package(name: "SwiftPango", path: "../../swift-gtk-fork/SwiftPango"),
        .package(name: "SwiftPangoCairo", path: "../../swift-gtk-fork/SwiftPangoCairo"),
        .package(name: "SwiftGdkPixbuf", path: "../../swift-gtk-fork/SwiftGdkPixbuf"),
        .package(name: "SwiftGraphene", path: "../../swift-gtk-fork/SwiftGraphene"),
        .package(name: "SwiftAtk", path: "../../swift-gtk-fork/SwiftAtk"),
        .package(name: "SwiftGdk", path: "../../swift-gtk-fork/SwiftGdk"),
        .package(name: "SwiftGsk", path: "../../swift-gtk-fork/SwiftGsk"),
        .package(name: "SwiftGtk", path: "../../swift-gtk-fork/SwiftGtk"),
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
                .copy("Resources/Typings"),
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
