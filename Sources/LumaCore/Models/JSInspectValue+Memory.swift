import Foundation

extension JSInspectValue {
    public func recordingMemory(_ written: [UInt8], at address: UInt64) -> JSInspectValue {
        switch self {
        case .bytes(let bytes):
            return .bytes(bytes.recordingMemory(written, at: address))
        case .object(let id, let properties):
            return .object(id: id, properties: properties.map { $0.recordingMemory(written, at: address) })
        case .array(let id, let elements):
            return .array(id: id, elements: elements.map { $0.recordingMemory(written, at: address) })
        case .map(let id, let entries):
            return .map(id: id, entries: entries.map { $0.recordingMemory(written, at: address) })
        case .set(let id, let elements):
            return .set(id: id, elements: elements.map { $0.recordingMemory(written, at: address) })
        default:
            return self
        }
    }

    public func bytes(readAt address: UInt64) -> Bytes? {
        if case .bytes(let bytes) = self {
            return bytes.address == address ? bytes : nil
        }
        return parts.lazy.compactMap { $0.bytes(readAt: address) }.first
    }

    private var parts: [JSInspectValue] {
        switch self {
        case .object(_, let properties):
            return properties.flatMap { [$0.key, $0.value] }
        case .map(_, let entries):
            return entries.flatMap { [$0.key, $0.value] }
        case .array(_, let elements), .set(_, let elements):
            return elements
        default:
            return []
        }
    }
}

extension JSInspectValue.Property {
    fileprivate func recordingMemory(_ written: [UInt8], at address: UInt64) -> JSInspectValue.Property {
        JSInspectValue.Property(
            key: key.recordingMemory(written, at: address),
            value: value.recordingMemory(written, at: address))
    }
}

extension JSInspectValue.Bytes {
    fileprivate func recordingMemory(_ written: [UInt8], at writtenStart: UInt64) -> JSInspectValue.Bytes {
        guard let start = address else { return self }
        let overlapStart = max(start, writtenStart)
        let overlapEnd = min(start &+ UInt64(data.count), writtenStart &+ UInt64(written.count))
        guard overlapStart < overlapEnd else { return self }
        var patched = [UInt8](data)
        patched.replaceSubrange(
            Int(overlapStart - start)..<Int(overlapEnd - start),
            with: written[Int(overlapStart - writtenStart)..<Int(overlapEnd - writtenStart)])
        return JSInspectValue.Bytes(data: Data(patched), kind: kind, address: address)
    }
}
