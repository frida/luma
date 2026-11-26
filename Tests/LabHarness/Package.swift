// swift-tools-version: 6.1
import Foundation
import PackageDescription

let harness = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let luma = harness.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased()
let infoPlist = harness.appendingPathComponent("Info.plist").path
let embedsInfoPlist: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]

let package = Package(
    name: "LabHarness",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "ChatCheck",
            dependencies: [.product(name: "LumaCore", package: luma)],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: embedsInfoPlist
        ),
        .executableTarget(
            name: "LabCheck",
            dependencies: [.product(name: "LumaCore", package: luma)],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: embedsInfoPlist
        ),
        .executableTarget(name: "LabTarget", cSettings: [.unsafeFlags(["-O1"])]),
    ]
)
