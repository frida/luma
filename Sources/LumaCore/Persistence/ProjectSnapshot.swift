import Foundation

public enum ProjectSnapshot {
    public static func snapshot(from workingURL: URL, to destination: URL) throws {
        BlobStore.settle()
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
