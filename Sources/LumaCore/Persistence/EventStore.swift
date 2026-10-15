import Foundation

public actor EventStore {
    public static let defaultByteCap: Int = 64 * 1024 * 1024
    public static let compactionLowWatermark: Double = 0.75

    private let fileURL: URL
    private let byteCap: Int
    private var fileSize: Int

    public init(fileURL: URL, byteCap: Int = defaultByteCap) {
        self.fileURL = fileURL
        self.byteCap = byteCap
        self.fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    }

    public func append(_ events: [RuntimeEvent]) {
        guard !events.isEmpty else { return }
        let payload = encodeBatch(events)
        guard !payload.isEmpty else { return }
        appendBytes(payload)
        if fileSize > byteCap {
            compact()
        }
    }

    public func loadAll() -> [RuntimeEvent] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        return decodeStream(handle)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        fileSize = 0
    }

    private func encodeBatch(_ events: [RuntimeEvent]) -> Data {
        var out = Data()
        for event in events {
            guard let obj = event.toLogJSON(),
                let bytes = try? JSONSerialization.data(withJSONObject: obj, options: [])
            else { continue }
            appendRecord(bytes, to: &out)
        }
        return out
    }

    private func appendRecord(_ payload: Data, to output: inout Data) {
        var lengthBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { output.append(contentsOf: $0) }
        output.append(payload)
    }

    private func appendBytes(_ bytes: Data) {
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: fileURL, options: .atomic)
        }
        fileSize += bytes.count
    }

    private func compact() {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        let target = Int(Double(byteCap) * Self.compactionLowWatermark)
        guard let dropOffset = findDropOffset(handle: handle, target: target) else { return }
        guard dropOffset > 0 else { return }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("events.log.\(UUID().uuidString).tmp")
        try? handle.seek(toOffset: UInt64(dropOffset))
        guard let tail = try? handle.readToEnd() else { return }
        do {
            try tail.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            fileSize = tail.count
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func findDropOffset(handle: FileHandle, target: Int) -> Int? {
        try? handle.seek(toOffset: 0)
        var offset = 0
        let total = fileSize
        while total - offset > target {
            try? handle.seek(toOffset: UInt64(offset))
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
            let length = Int(readUInt32BE(header))
            try? handle.seek(toOffset: UInt64(offset + 4 + length))
            offset += 4 + length
        }
        return offset
    }

    private func decodeStream(_ handle: FileHandle) -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        var indexByID: [RuntimeEvent.ID: Int] = [:]
        while let header = try? handle.read(upToCount: 4), header.count == 4 {
            let length = Int(readUInt32BE(header))
            guard let body = try? handle.read(upToCount: length), body.count == length else { break }
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let event = RuntimeEvent.fromLogJSON(obj)
            else { continue }
            if let index = indexByID[event.id] {
                events[index] = event
            } else {
                indexByID[event.id] = events.count
                events.append(event)
            }
        }
        return events
    }

    private func readUInt32BE(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
    }
}
