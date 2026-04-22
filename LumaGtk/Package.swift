// swift-tools-version: 6.0

import Foundation
import PackageDescription

func pkgConfigFlags(_ packages: [String], libs: Bool = false) -> [String] {
    guard let pkgConfigPath = findOnPath("pkg-config") else { return [] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pkgConfigPath)
    proc.arguments = (libs ? ["--libs"] : ["--cflags"]) + packages
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

func findOnPath(_ name: String) -> String? {
    #if os(Windows)
    let separator: Character = ";"
    let extensions = ["", ".exe", ".cmd", ".bat"]
    let pathSep = "\\"
    #else
    let separator: Character = ":"
    let extensions = [""]
    let pathSep = "/"
    #endif
    let env = ProcessInfo.processInfo.environment
    guard let pathValue = env["PATH"] ?? env["Path"] else { return nil }
    for dir in pathValue.split(separator: separator).map(String.init) where !dir.isEmpty {
        for ext in extensions {
            let candidate = dir + pathSep + name + ext
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
    }
    return nil
}

let lumaGtkTargetDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/LumaGtk", isDirectory: true).path

// SwiftPM rejects exclude entries that don't exist on disk. luma.rc is
// only meaningful to the Windows build, and luma.res is the rc.exe
// output produced at manifest-evaluation time — both are absent on
// Linux/macOS. Only exclude what's actually there.
let lumaGtkExcludes: [String] = ["luma.rc", "luma.res"].filter { name in
    FileManager.default.fileExists(atPath: lumaGtkTargetDir + "/" + name)
}

#if os(Windows)
func compileWindowsExecutableIcon() -> String? {
    let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    let rcFile = pkg + "\\Sources\\LumaGtk\\luma.rc"
    let resFile = pkg + "\\Sources\\LumaGtk\\luma.res"
    guard FileManager.default.fileExists(atPath: rcFile) else { return nil }
    if let rc = findOnPath("rc") {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rc)
        proc.arguments = ["/nologo", "/fo", resFile, rcFile]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return resFile }
    }
    return FileManager.default.fileExists(atPath: resFile) ? resFile : nil
}
let lumaExecutableIconResource = compileWindowsExecutableIcon()
#endif

#if os(macOS)
let cLumaSources: [String] = ["shim_gtk.c", "shim_webkit.m"]
let cLumaCSettings: [CSetting] = [
    .unsafeFlags(pkgConfigFlags(["gtk4"])),
]
let cLumaCxxSettings: [CXXSetting] = []
let cLumaLinkerSettings: [LinkerSetting] = [
    .linkedFramework("WebKit"),
]
let lumaGtkLinkerSettings: [LinkerSetting] = []
#elseif os(Windows)
let cLumaSources: [String] = ["shim_gtk.c", "shim_webview2.cpp"]
let cLumaCSettings: [CSetting] = [
    .unsafeFlags(pkgConfigFlags(["gtk4"])),
]
let cLumaCxxSettings: [CXXSetting] = [
    .unsafeFlags(pkgConfigFlags(["gtk4"])),
]
let cLumaLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("WebView2Loader.dll"),
    .linkedLibrary("ole32"),
    .linkedLibrary("oleaut32"),
    .linkedLibrary("runtimeobject"),
]
// Windows: produce a GUI app (no console window). Swift's runtime
// still calls main(), so redirect the linker entry to the C runtime's
// main-compatible start routine rather than WinMain. Tool binaries
// built by SwiftPM plugins (gir2swift-tool, Yams-tool, ...) need the
// default console subsystem, so keep these target-scoped.
//
// The /ignore:* warning filters also apply to those tool binaries and
// can't be set on targets outside this package — they live on the
// swift build command line (see scripts/windows/build.ps1 and the
// Windows CI job).
let windowsGuiLinkerFlags = ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]
let lumaGtkLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(windowsGuiLinkerFlags + (lumaExecutableIconResource.map { [$0] } ?? []))
]
#else
let cLumaSources: [String] = ["shim_gtk.c", "shim_webkitgtk.c"]
let cLumaCSettings: [CSetting] = [
    .unsafeFlags(
        pkgConfigFlags(["webkitgtk-6.0", "gtk4", "libsoup-3.0"])
    ),
]
let cLumaCxxSettings: [CXXSetting] = []
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
        .package(name: "luma", path: ".."),
        .package(url: "https://github.com/frida/SwiftGtk.git", branch: "gtk4-development"),
        .package(url: "https://github.com/frida/SwiftAdw.git", branch: "development"),
    ],
    targets: [
        .target(
            name: "CLuma",
            path: "Sources/CLuma",
            sources: cLumaSources,
            publicHeadersPath: "include",
            cSettings: cLumaCSettings,
            cxxSettings: cLumaCxxSettings,
            linkerSettings: cLumaLinkerSettings
        ),
        .executableTarget(
            name: "LumaGtk",
            dependencies: [
                .product(name: "LumaCore", package: "luma"),
                .product(name: "Gtk", package: "SwiftGtk"),
                .product(name: "Adw", package: "SwiftAdw"),
                "CLuma",
            ],
            path: "Sources/LumaGtk",
            exclude: lumaGtkExcludes,
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
