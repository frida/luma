import Foundation
import Observation

@Observable
@MainActor
public final class VirtualMachineConsole {
    public private(set) var lines: [VirtualMachineConsoleLine] = []
    public private(set) var firstLineNumber = 0
    public private(set) var lastAlarmLineNumber: Int?

    @ObservationIgnored private let transcript: FileHandle?

    public init(transcript url: URL) {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        transcript = FileHandle(forWritingAtPath: url.path)
    }

    public var endLineNumber: Int {
        firstLineNumber + lines.count
    }

    public func lines(from lineNumber: Int) -> ArraySlice<VirtualMachineConsoleLine> {
        lines[(max(lineNumber, firstLineNumber) - firstLineNumber)...]
    }

    func follow(_ handle: FileHandle) {
        Task { [weak self] in
            for await text in handle.lines {
                self?.append(text)
            }
        }
    }

    func append(_ text: String, alarming: Bool? = nil) {
        let line = VirtualMachineConsoleLine(text: text.hasSuffix("\r") ? String(text.dropLast()) : text, alarming: alarming)
        if line.isAlarming {
            lastAlarmLineNumber = endLineNumber
        }
        lines.append(line)
        transcript?.write(Data((line.text + "\n").utf8))
        dropLinesBeyondCapacity()
    }

    private func dropLinesBeyondCapacity() {
        guard lines.count > Self.capacity + Self.trimBatch else { return }
        lines.removeFirst(Self.trimBatch)
        firstLineNumber += Self.trimBatch
    }

    private static let capacity = 5000
    private static let trimBatch = 500
}

public struct VirtualMachineConsoleLine: Sendable {
    public let text: String
    public let isAlarming: Bool

    init(text: String, alarming: Bool?) {
        self.text = text
        self.isAlarming = alarming ?? Self.alarmSigns.contains { text.contains($0) }
    }

    private static let alarmSigns = ["Kernel panic", "Oops", "BUG:", "Call trace:", "FATAL", "ERROR"]
}
