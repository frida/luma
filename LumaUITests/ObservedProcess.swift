import Foundation

@MainActor
final class ObservedProcess {
    static let processName = "observed"
    let binaryURL: URL
    var processName: String { Self.processName }
    private var process: Process?

    init() throws {
        let bundle = Bundle(for: ObservedProcess.self)
        guard let url = bundle.url(forResource: "observed", withExtension: nil) else {
            throw ObservedProcessError.binaryMissing
        }
        binaryURL = url
    }

    func launch() throws {
        let p = Process()
        p.executableURL = binaryURL
        let devnull = FileHandle(forWritingAtPath: "/dev/null")!
        p.standardOutput = devnull
        p.standardError = devnull
        try p.run()
        process = p
    }

    func terminate() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
    }
}

enum ObservedProcessError: Error, CustomStringConvertible {
    case binaryMissing

    var description: String {
        switch self {
        case .binaryMissing:
            return "observed fixture not found in test bundle — check the 'Build observed.c fixture' build phase"
        }
    }
}
