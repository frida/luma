// swift-tools-version: 6.0

import Foundation
import PackageDescription

func pkgConfigFlags(_ packages: [String], libs: Bool = false) -> [String] {
    let proc = Process()
    #if os(Windows)
    proc.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
    proc.arguments = ["/c", "pkg-config"] + (libs ? ["--libs"] : ["--cflags"]) + packages
    #else
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["pkg-config"] + (libs ? ["--libs"] : ["--cflags"]) + packages
    #endif
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
        .map(String.init) ?? []
}

#if os(macOS)
let cLumaSources: [String] = ["shim_gtk.c", "shim_webkit.m"]
let cLumaCSettings: [CSetting] = [
    .unsafeFlags(pkgConfigFlags(["gtk4"])),
]
let cLumaLinkerSettings: [LinkerSetting] = [
    .linkedFramework("WebKit"),
]
let lumaGtkLinkerSettings: [LinkerSetting] = []
#elseif os(Windows)
let cLumaSources: [String] = ["shim_gtk.c", "shim_webview2.c"]
let cLumaCSettings: [CSetting] = [
    .unsafeFlags(pkgConfigFlags(["gtk4"])),
]
let cLumaLinkerSettings: [LinkerSetting] = []
let lumaGtkLinkerSettings: [LinkerSetting] = []
#else
let cLumaSources: [String] = ["shim_gtk.c", "shim_webkitgtk.c"]
let cLumaCSettings: [CSetting] = [
    .unsafeFlags(
        pkgConfigFlags(["webkitgtk-6.0", "gtk4", "libsoup-3.0"])
    ),
]
let cLumaLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("webkitgtk-6.0"),
    .linkedLibrary("javascriptcoregtk-6.0"),
]
let lumaGtkLinkerSettings: [LinkerSetting] = [
    // Fedora's Swift 6.2 ships libswiftObservation.so with an unresolved
    // reference to swift::threading::fatal that no other shipped library
    // exports. Until upstream fixes the packaging, allow the dynamic
    // linker to defer the symbol — it's only ever called on a fatal
    // assertion path inside Observation.
    .unsafeFlags(["-Xlinker", "--allow-shlib-undefined"]),
]
#endif

let package = Package(
    name: "LumaGtk",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/frida/SwiftGtk.git", branch: "gtk4-development"),
        .package(url: "https://github.com/frida/gir2swift.git", branch: "development"),
        .package(url: "https://github.com/frida/SwiftLibXML.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "CLuma",
            path: "Sources/CLuma",
            sources: cLumaSources,
            publicHeadersPath: "include",
            cSettings: cLumaCSettings,
            linkerSettings: cLumaLinkerSettings
        ),
        .executableTarget(
            name: "LumaGtk",
            dependencies: [
                .product(name: "LumaCore", package: "luma"),
                .product(name: "Gtk", package: "SwiftGtk"),
                "CLuma",
            ],
            path: "Sources/LumaGtk",
            resources: [
                .copy("Resources/MonacoWeb"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: lumaGtkLinkerSettings
        ),
    ]
)
