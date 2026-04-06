import Foundation
import LumaCore
import SwiftyR2

final class ITraceIOProvider: R2IOAsyncProvider, @unchecked Sendable {
    private let blockBytes: [UInt64: Data]
    private weak var processNode: ProcessNodeViewModel?

    init(blockBytes: [UInt64: Data], processNode: ProcessNodeViewModel?) {
        self.blockBytes = blockBytes
        self.processNode = processNode
    }

    func supports(path: String, many: Bool) -> Bool {
        path.hasPrefix("itrace://")
    }

    func open(path: String, access: R2IOAccess, mode: Int32) async throws -> R2IOAsyncFile {
        ITraceIOFile(blockBytes: blockBytes, processNode: processNode)
    }
}

private final class ITraceIOFile: R2IOAsyncFile, @unchecked Sendable {
    private let blockBytes: [UInt64: Data]
    private weak var processNode: ProcessNodeViewModel?

    init(blockBytes: [UInt64: Data], processNode: ProcessNodeViewModel?) {
        self.blockBytes = blockBytes
        self.processNode = processNode
    }

    func close() async throws {}

    func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        // Check recorded block bytes for any overlap with the
        // requested range.
        let reqStart = offset
        let reqEnd = offset + UInt64(count)

        for (blockAddr, data) in blockBytes {
            let blockEnd = blockAddr + UInt64(data.count)

            guard reqStart < blockEnd, reqEnd > blockAddr else {
                continue
            }

            // There is overlap. Build the result from the overlay,
            // filling gaps from live memory or zeros.
            var result = [UInt8](repeating: 0, count: count)

            // Fill from overlay.
            let overlapStart = max(reqStart, blockAddr)
            let overlapEnd = min(reqEnd, blockEnd)
            let srcOffset = Int(overlapStart - blockAddr)
            let dstOffset = Int(overlapStart - reqStart)
            let overlapLen = Int(overlapEnd - overlapStart)
            data.copyBytes(
                to: &result[dstOffset],
                from: srcOffset..<(srcOffset + overlapLen)
            )

            // Fill prefix from live memory if needed.
            if reqStart < blockAddr {
                let prefixLen = Int(blockAddr - reqStart)
                if let liveBytes = try? await readLive(at: reqStart, count: prefixLen) {
                    result.replaceSubrange(0..<prefixLen, with: liveBytes.prefix(prefixLen))
                }
            }

            // Fill suffix from live memory if needed.
            if reqEnd > blockEnd {
                let suffixStart = blockEnd
                let suffixLen = Int(reqEnd - blockEnd)
                let dstStart = Int(suffixStart - reqStart)
                if let liveBytes = try? await readLive(at: suffixStart, count: suffixLen) {
                    result.replaceSubrange(dstStart..<(dstStart + suffixLen), with: liveBytes.prefix(suffixLen))
                }
            }

            return result
        }

        // No overlay; try live memory.
        if let liveBytes = try? await readLive(at: offset, count: count) {
            return liveBytes
        }

        return [UInt8](repeating: 0, count: count)
    }

    private func readLive(at address: UInt64, count: Int) async throws -> [UInt8] {
        guard let processNode else {
            throw NSError(domain: "ITrace", code: 1, userInfo: [NSLocalizedDescriptionKey: "Process not available"])
        }
        return try await processNode.core.readRemoteMemory(at: address, count: count)
    }

    func write(at offset: UInt64, bytes: [UInt8]) async throws -> Int { 0 }
    func size() async throws -> UInt64 { UInt64.max }
    func setSize(_ size: UInt64) async throws {}
}
