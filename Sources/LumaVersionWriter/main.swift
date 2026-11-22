import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    fail("usage: LumaVersionWriter <package-root> <output> [version]")
}
let packageRoot = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
let version = arguments.count == 4 ? arguments[3] : versionFromScript(in: packageRoot)
let source = """
    public enum LumaVersion {
        public static let string = "\(version)"
    }

    """

let written = try? String(contentsOf: output, encoding: .utf8)
if written != source {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try source.write(to: output, atomically: true, encoding: .utf8)
}

func versionFromScript(in packageRoot: URL) -> String {
    let script = Process()
    let printed = Pipe()
    script.executableURL = URL(fileURLWithPath: "/bin/bash")
    script.arguments = [packageRoot.appendingPathComponent("Scripts/luma-version.sh").path]
    script.standardOutput = printed
    do {
        try script.run()
    } catch {
        fail("LUMA_VERSION is not set, and Scripts/luma-version.sh did not start: \(error)")
    }
    let text = String(decoding: printed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    script.waitUntilExit()
    let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard script.terminationStatus == 0, !version.isEmpty else {
        fail("Scripts/luma-version.sh did not say which version this is")
    }
    return version
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
