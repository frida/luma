import CoreGraphics
import Foundation

struct DecodedITrace {
    let registerNames: [String]
    var entries: [TraceEntry]
    let blockBytes: [UInt64: Data]
}

struct TraceEntry {
    let blockAddress: UInt64
    let blockSize: Int
    var blockName: String
    let registerWrites: [RegisterWrite]
}

struct RegisterWrite {
    let blockOffset: Int
    let registerName: String
    let registerIndex: Int
    let value: UInt64
}

struct ITraceMetadata: Codable {
    let hookId: String
    let callIndex: Int
    let hookTarget: String?
    let prologueBytes: String?
    let regSpecs: [RegisterSpec]
    var blocks: [BlockSpec]

    struct RegisterSpec: Codable {
        let name: String
        let size: Int
    }

    struct BlockSpec: Codable {
        var name: String
        let address: String
        let size: Int
        let bytes: String?
        let module: ModuleRef?
        let writes: [[Int]]

        struct ModuleRef: Codable {
            let path: String
            let base: String
        }
    }
}

enum ITraceDecoder {

    /// Decode trace data and metadata into a structured trace.
    /// Expects already-cleaned metadata (noise trimmed, prologue merged).
    static func decode(traceData: Data, metadataJSON: Data) throws -> DecodedITrace {
        let metadata = try JSONDecoder().decode(ITraceMetadata.self, from: metadataJSON)

        let registerNames = metadata.regSpecs.map(\.name)

        let blocksByAddress = Dictionary(
            uniqueKeysWithValues: metadata.blocks.compactMap { block -> (UInt64, ITraceMetadata.BlockSpec)? in
                guard let addr = parseHexAddress(block.address) else { return nil }
                return (addr, block)
            }
        )

        var blockBytesMap: [UInt64: Data] = [:]
        for block in metadata.blocks {
            guard let addr = parseHexAddress(block.address),
                let hex = block.bytes, !hex.isEmpty,
                let data = hexToData(hex)
            else { continue }
            blockBytesMap[addr] = data
        }

        var entries: [TraceEntry] = []

        var offset = 0
        let bytes = [UInt8](traceData)

        while offset + 8 <= bytes.count {
            let blockAddress = readUInt64(bytes, at: offset)
            offset += 8

            guard let block = blocksByAddress[blockAddress] else {
                break
            }

            var writes: [RegisterWrite] = []

            for pair in block.writes {
                guard pair.count == 2 else { continue }
                let blockOffset = pair[0]
                let registerIndex = pair[1]

                guard registerIndex < metadata.regSpecs.count else {
                    offset += 8
                    continue
                }

                let spec = metadata.regSpecs[registerIndex]
                let valueSize = spec.size

                guard offset + valueSize <= bytes.count else { break }

                let value: UInt64
                if valueSize <= 8 {
                    value = readUIntN(bytes, at: offset, size: valueSize)
                } else {
                    value = readUInt64(bytes, at: offset)
                }
                offset += valueSize

                writes.append(RegisterWrite(
                    blockOffset: blockOffset,
                    registerName: spec.name,
                    registerIndex: registerIndex,
                    value: value
                ))
            }

            entries.append(TraceEntry(
                blockAddress: blockAddress,
                blockSize: block.size,
                blockName: block.name,
                registerWrites: writes
            ))
        }

        return DecodedITrace(
            registerNames: registerNames,
            entries: entries,
            blockBytes: blockBytesMap
        )
    }

    /// Clean up raw capture metadata: remove Interceptor noise blocks,
    /// merge the trampoline prologue with the first real block, and
    /// rewrite the trace data to match. Called once at capture time.
    static func cleanupAfterCapture(
        traceData: inout Data,
        metadataJSON: inout Data
    ) {
        guard var metadata = try? JSONDecoder().decode(ITraceMetadata.self, from: metadataJSON) else { return }

        let hookTarget = metadata.hookTarget.flatMap { parseHexAddress($0) }
        let prologueData = metadata.prologueBytes.flatMap { hexToData($0) }

        // Identify meaningful blocks (those with a module name).
        let meaningfulAddresses = Set(
            metadata.blocks
                .filter { $0.name.contains("!") }
                .compactMap { parseHexAddress($0.address) }
        )

        guard !meaningfulAddresses.isEmpty else { return }

        // Decode the raw trace to find the entry boundaries.
        let rawTrace = try? decode(traceData: traceData, metadataJSON: metadataJSON)
        guard let rawTrace, !rawTrace.entries.isEmpty else { return }

        let firstMeaningfulIdx = rawTrace.entries.firstIndex { $0.blockName.contains("!") }
        let lastMeaningfulIdx = rawTrace.entries.lastIndex { $0.blockName.contains("!") }
        guard let firstMeaningfulIdx, let lastMeaningfulIdx else { return }

        // Trim entries to meaningful range.
        var cleanEntries = Array(rawTrace.entries[firstMeaningfulIdx...lastMeaningfulIdx])

        // Merge the trampoline prologue with the first real block.
        if let hookTarget, let prologueData,
            firstMeaningfulIdx > 0
        {
            let firstEntry = cleanEntries[0]
            let overwrittenSize = Int(firstEntry.blockAddress - hookTarget)

            if overwrittenSize > 0, overwrittenSize <= prologueData.count {
                // Register restore block: all saved register values.
                var restoreWrites: [RegisterWrite] = []
                if firstMeaningfulIdx >= 2 {
                    let restoreEntry = rawTrace.entries[firstMeaningfulIdx - 2]
                    restoreWrites = deduplicateAndSort(Array(restoreEntry.registerWrites.dropFirst()))
                }

                // Trampoline block: drop first (LR) and last (X16) writes.
                let trampolineEntry = rawTrace.entries[firstMeaningfulIdx - 1]
                var trampolineWrites = Array(trampolineEntry.registerWrites.dropFirst())
                if trampolineWrites.last?.registerName == "x16" {
                    trampolineWrites.removeLast()
                }
                trampolineWrites = deduplicateAndSort(trampolineWrites)

                // First meaningful block: drop first (LR), shift offsets.
                let shiftedWrites = Array(firstEntry.registerWrites.dropFirst()).map { write in
                    RegisterWrite(
                        blockOffset: write.blockOffset + overwrittenSize,
                        registerName: write.registerName,
                        registerIndex: write.registerIndex,
                        value: write.value
                    )
                }

                let mergedWrites = restoreWrites + trampolineWrites + shiftedWrites

                // Build merged block bytes.
                var mergedBytesData = Data(prologueData.prefix(overwrittenSize))
                if let realHex = metadata.blocks.first(where: { parseHexAddress($0.address) == firstEntry.blockAddress })?.bytes,
                    let realBytes = hexToData(realHex)
                {
                    mergedBytesData.append(realBytes)
                }

                // Derive merged name.
                let bangIdx = firstEntry.blockName.firstIndex(of: "!")!
                let moduleName = firstEntry.blockName[...firstEntry.blockName.index(before: bangIdx)]
                let origOffset = parseHexAddress(
                    String(firstEntry.blockName[firstEntry.blockName.index(after: bangIdx)...]))!
                let mergedName = "\(moduleName)!0x\(String(origOffset - UInt64(overwrittenSize), radix: 16))"

                // Build merged block spec for the metadata.
                let mergedBlockSpec = ITraceMetadata.BlockSpec(
                    name: mergedName,
                    address: String(format: "0x%llx", hookTarget),
                    size: mergedBytesData.count,
                    bytes: dataToHex(mergedBytesData),
                    module: metadata.blocks.first { $0.name.contains("!") }?.module,
                    writes: mergedWrites.map { [$0.blockOffset, $0.registerIndex] }
                )

                cleanEntries[0] = TraceEntry(
                    blockAddress: hookTarget,
                    blockSize: mergedBytesData.count,
                    blockName: mergedName,
                    registerWrites: mergedWrites
                )

                // Replace metadata blocks: merged first + remaining meaningful.
                var cleanBlocks = [mergedBlockSpec]
                for block in metadata.blocks where block.name.contains("!") {
                    let addr = parseHexAddress(block.address)
                    if addr != firstEntry.blockAddress {
                        cleanBlocks.append(block)
                    }
                }
                metadata.blocks = cleanBlocks
            }
        } else {
            // No merge needed; just keep meaningful blocks.
            metadata.blocks = metadata.blocks.filter { $0.name.contains("!") }
        }

        // Rebuild trace data from clean entries.
        traceData = rebuildTraceData(entries: cleanEntries, metadata: metadata)

        // Persist cleaned metadata.
        if let data = try? JSONEncoder().encode(metadata) {
            metadataJSON = data
        }
    }

    /// Rebuild binary trace data from decoded entries.
    private static func rebuildTraceData(entries: [TraceEntry], metadata: ITraceMetadata) -> Data {
        var out = Data()

        for entry in entries {
            // Block address (8 bytes, little-endian).
            var addr = entry.blockAddress
            out.append(Data(bytes: &addr, count: 8))

            // Register writes.
            for write in entry.registerWrites {
                guard write.registerIndex < metadata.regSpecs.count else { continue }
                let size = metadata.regSpecs[write.registerIndex].size
                var value = write.value
                out.append(Data(bytes: &value, count: min(size, 8)))
                if size > 8 {
                    // Pad vector registers with zeros.
                    out.append(Data(repeating: 0, count: size - 8))
                }
            }
        }

        return out
    }

    /// Keep only the last write per register, then sort by register index.
    private static func deduplicateAndSort(_ writes: [RegisterWrite]) -> [RegisterWrite] {
        var lastByIndex: [Int: RegisterWrite] = [:]
        for w in writes { lastByIndex[w.registerIndex] = w }
        return lastByIndex.values.sorted { $0.registerIndex < $1.registerIndex }
    }

    // MARK: - Helpers

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (i * 8)
        }
        return value
    }

    private static func readUIntN(_ bytes: [UInt8], at offset: Int, size: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<min(size, 8) {
            value |= UInt64(bytes[offset + i]) << (i * 8)
        }
        return value
    }

    static func parseHexAddress(_ s: String) -> UInt64? {
        let str = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        return UInt64(str, radix: 16)
    }

    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var chars = hex.makeIterator()
        while let hi = chars.next(), let lo = chars.next() {
            guard let byte = UInt8(String([hi, lo]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    private static func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
