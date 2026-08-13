import Foundation
import LumaCore
import SwiftyPharo

/// Reads the example catalogue in the image, so what nothing else looks at is
/// looked at somewhere.

CoreTextGlyphAtlas.install()
PharoWorkspace.boot()
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
