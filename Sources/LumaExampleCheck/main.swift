import Foundation
import LumaCore
import SwiftyPharo

/// Reads the example catalogue in the image, so what nothing else looks at is
/// looked at somewhere. Takes the image to read it with:
///
///     LumaExampleCheck <path to SwiftyPharo.image>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: LumaExampleCheck <image>\n".utf8))
    exit(2)
}

let image = URL(fileURLWithPath: arguments[1])
CoreTextGlyphAtlas.install()
PharoRuntime.shared.boot(image: image)
try await PharoRuntime.shared.runningState()
try await PharoLumaBindings.install(into: PharoRuntime.shared)

let complaints = try await PharoExampleCheck.run(in: PharoRuntime.shared)
guard complaints.isEmpty else {
    FileHandle.standardError.write(Data((complaints.joined(separator: "\n") + "\n").utf8))
    FileHandle.standardError.write(
        Data("\(complaints.count) complaint(s) about the example catalogue\n".utf8))
    exit(1)
}

print("the example catalogue reads clean")
exit(0)
