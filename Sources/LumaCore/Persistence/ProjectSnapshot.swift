import Foundation

public enum ProjectSnapshot {
    public static func write(workingURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("luma-save-\(UUID().uuidString).luma", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try snapshot(from: workingURL, to: staging)

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: staging, to: destination)
        }
    }

    public static func snapshot(from workingURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let dbSource = workingURL.appendingPathComponent("db.sqlite")
        let dbDest = destination.appendingPathComponent("db.sqlite")
        try ProjectStore.exportSnapshot(from: dbSource, to: dbDest)

        let tracesSource = workingURL.appendingPathComponent("traces", isDirectory: true)
        let tracesDest = destination.appendingPathComponent("traces", isDirectory: true)
        if fm.fileExists(atPath: tracesSource.path) {
            try fm.copyItem(at: tracesSource, to: tracesDest)
        }

        let eventsSource = workingURL.appendingPathComponent("events.log")
        let eventsDest = destination.appendingPathComponent("events.log")
        if fm.fileExists(atPath: eventsSource.path) {
            try fm.copyItem(at: eventsSource, to: eventsDest)
        }
    }
}
