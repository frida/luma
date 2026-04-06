import Foundation

public struct DecodedITrace {
    public let registerNames: [String]
    public var entries: [TraceEntry]
    public let blockBytes: [UInt64: Data]
    public let functionCalls: [TraceFunctionCall]
    public let registerStates: [RegisterState]

    public init(
        registerNames: [String],
        entries: [TraceEntry],
        blockBytes: [UInt64: Data],
        functionCalls: [TraceFunctionCall],
        registerStates: [RegisterState]
    ) {
        self.registerNames = registerNames
        self.entries = entries
        self.blockBytes = blockBytes
        self.functionCalls = functionCalls
        self.registerStates = registerStates
    }
}

public struct RegisterState {
    public let values: [Int: UInt64]
    public let changed: Set<Int>

    public init(values: [Int: UInt64], changed: Set<Int>) {
        self.values = values
        self.changed = changed
    }
}

public struct TraceFunctionCall {
    public let functionName: String
    public let startIndex: Int
    public let endIndex: Int

    public var entryCount: Int { endIndex - startIndex }

    public var shortName: String {
        if let bang = functionName.firstIndex(of: "!") {
            return String(functionName[functionName.index(after: bang)...])
        }
        return functionName
    }

    public init(functionName: String, startIndex: Int, endIndex: Int) {
        self.functionName = functionName
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

public struct TraceEntry {
    public let blockAddress: UInt64
    public let blockSize: Int
    public var blockName: String
    public let registerWrites: [RegisterWrite]

    public init(blockAddress: UInt64, blockSize: Int, blockName: String, registerWrites: [RegisterWrite]) {
        self.blockAddress = blockAddress
        self.blockSize = blockSize
        self.blockName = blockName
        self.registerWrites = registerWrites
    }
}

public struct RegisterWrite {
    public let blockOffset: Int
    public let registerName: String
    public let registerIndex: Int
    public let value: UInt64

    public init(blockOffset: Int, registerName: String, registerIndex: Int, value: UInt64) {
        self.blockOffset = blockOffset
        self.registerName = registerName
        self.registerIndex = registerIndex
        self.value = value
    }
}

public struct ITraceMetadata: Codable {
    public let hookId: String
    public let callIndex: Int
    public let hookTarget: String?
    public let prologueBytes: String?
    public let regSpecs: [RegisterSpec]
    public var blocks: [BlockSpec]

    public struct RegisterSpec: Codable {
        public let name: String
        public let size: Int
    }

    public struct BlockSpec: Codable {
        public var name: String
        public let address: String
        public let size: Int
        public let bytes: String?
        public let module: ModuleRef?
        public let writes: [[Int]]

        public struct ModuleRef: Codable {
            public let path: String
            public let base: String
        }

        public init(name: String, address: String, size: Int, bytes: String?, module: ModuleRef?, writes: [[Int]]) {
            self.name = name
            self.address = address
            self.size = size
            self.bytes = bytes
            self.module = module
            self.writes = writes
        }
    }
}

public enum ITraceDecoder {

    public static func decode(traceData: Data, metadataJSON: Data) throws -> DecodedITrace {
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

        let functionCalls = groupIntoFunctionCalls(entries)
        let registerStates = computeRegisterStates(entries)

        return DecodedITrace(
            registerNames: registerNames,
            entries: entries,
            blockBytes: blockBytesMap,
            functionCalls: functionCalls,
            registerStates: registerStates
        )
    }

    // MARK: - Binary Buffer Parsing (frida-itrace v5)

    public static func parseRawBuffer(
        _ rawData: Data,
        hookTarget: String?,
        prologueBytes: String?
    ) -> (traceData: Data, metadataJSON: Data) {
        let bytes = [UInt8](rawData)
        var offset = 0

        var regSpecs: [[String: Any]] = []
        var blocks: [[String: Any]] = []
        var traceRecords = Data()
        var blockRecordSizes: [UInt64: Int] = [:]

        while offset + 8 <= bytes.count {
            let sentinel = readUInt64(bytes, at: offset)

            if sentinel != 0 {
                guard let recordSize = blockRecordSizes[sentinel] else {
                    break
                }
                guard offset + recordSize <= bytes.count else { break }
                traceRecords.append(contentsOf: bytes[offset..<(offset + recordSize)])
                offset += recordSize
            } else {
                guard offset + 16 <= bytes.count else { break }
                let eventType = readUInt32(bytes, at: offset + 8)
                let payloadSize = Int(readUInt32(bytes, at: offset + 12))
                let payloadStart = offset + 16
                guard payloadStart + payloadSize <= bytes.count else { break }

                switch eventType {
                case 1:
                    let block = parseCompileEvent(bytes, at: payloadStart, size: payloadSize)
                    if let addr = block["address"] as? UInt64,
                        let recordSize = block["record_size"] as? Int
                    {
                        blockRecordSizes[addr] = recordSize
                    }
                    blocks.append(serializeBlockForJSON(block))

                case 2:
                    regSpecs = parseStartEvent(bytes, at: payloadStart, size: payloadSize)

                case 3:
                    break

                case 4:
                    let msg = String(bytes: bytes[payloadStart..<(payloadStart + payloadSize)], encoding: .utf8) ?? "unknown"
                    print("[itrace] panic: \(msg)")

                default:
                    break
                }

                offset = payloadStart + payloadSize
            }
        }

        var metadata: [String: Any] = [
            "hookId": "",
            "callIndex": 0,
            "regSpecs": regSpecs,
            "blocks": blocks,
        ]
        if let hookTarget { metadata["hookTarget"] = hookTarget }
        if let prologueBytes { metadata["prologueBytes"] = prologueBytes }

        let metadataJSON = (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data()

        return (traceData: traceRecords, metadataJSON: metadataJSON)
    }

    private static func parseCompileEvent(_ bytes: [UInt8], at start: Int, size: Int) -> [String: Any] {
        var o = start
        let blockAddress = readUInt64(bytes, at: o); o += 8
        let blockSize = readUInt32(bytes, at: o); o += 4
        let recordSize = readUInt32(bytes, at: o); o += 4
        let numWrites = Int(readUInt16(bytes, at: o)); o += 2
        let nameSize = Int(readUInt16(bytes, at: o)); o += 2
        _ = readUInt64(bytes, at: o); o += 8
        _ = readUInt32(bytes, at: o); o += 4
        let moduleBase = readUInt64(bytes, at: o); o += 8
        let modulePathSize = Int(readUInt16(bytes, at: o)); o += 2
        _ = readUInt16(bytes, at: o); o += 2

        var writes: [[Int]] = []
        for _ in 0..<numWrites {
            let blockOffset = Int(readUInt32(bytes, at: o)); o += 4
            let regIndex = Int(readUInt32(bytes, at: o)); o += 4
            writes.append([blockOffset, regIndex])
        }

        let name: String
        if nameSize > 0, o + nameSize <= bytes.count {
            name = String(bytes: bytes[o..<(o + nameSize)], encoding: .utf8) ?? ""
            o += nameSize
        } else {
            name = String(format: "0x%llx", blockAddress)
        }

        var modulePath: String?
        if modulePathSize > 0, o + modulePathSize <= bytes.count {
            modulePath = String(bytes: bytes[o..<(o + modulePathSize)], encoding: .utf8)
            o += modulePathSize
        }

        let bSize = Int(blockSize)
        var codeHex = ""
        if bSize > 0, o + bSize <= bytes.count {
            codeHex = Data(bytes[o..<(o + bSize)]).map { String(format: "%02x", $0) }.joined()
            o += bSize
        }

        var result: [String: Any] = [
            "address": blockAddress,
            "record_size": Int(recordSize),
            "name": name,
            "size": bSize,
            "writes": writes,
            "bytes": codeHex,
        ]

        if moduleBase != 0 {
            result["module"] = [
                "path": modulePath ?? "",
                "base": String(format: "0x%llx", moduleBase),
            ]
        }

        return result
    }

    private static func serializeBlockForJSON(_ block: [String: Any]) -> [String: Any] {
        var json = block
        if let addr = json["address"] as? UInt64 {
            json["address"] = String(format: "0x%llx", addr)
        }
        json.removeValue(forKey: "record_size")
        return json
    }

    private static func parseStartEvent(_ bytes: [UInt8], at start: Int, size: Int) -> [[String: Any]] {
        var o = start
        let numRegs = Int(readUInt32(bytes, at: o)); o += 4
        _ = readUInt32(bytes, at: o); o += 4

        var specs: [[String: Any]] = []
        for _ in 0..<numRegs {
            guard o + 8 <= bytes.count else { break }
            let nameLen = Int(bytes[o]); o += 1
            let nameBytes = bytes[o..<(o + min(nameLen, 6))]
            let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
            o += 6
            let regSize = Int(bytes[o]); o += 1
            specs.append(["name": name, "size": regSize])
        }

        return specs
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(bytes[offset + i]) << (i * 8)
        }
        return value
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    public static func cleanupAfterCapture(
        traceData: inout Data,
        metadataJSON: inout Data
    ) {
        guard var metadata = try? JSONDecoder().decode(ITraceMetadata.self, from: metadataJSON) else { return }

        let hookTarget = metadata.hookTarget.flatMap { parseHexAddress($0) }
        let prologueData = metadata.prologueBytes.flatMap { hexToData($0) }

        let meaningfulAddresses = Set(
            metadata.blocks
                .filter { $0.name.contains("!") }
                .compactMap { parseHexAddress($0.address) }
        )

        guard !meaningfulAddresses.isEmpty else { return }

        let rawTrace = try? decode(traceData: traceData, metadataJSON: metadataJSON)
        guard let rawTrace, !rawTrace.entries.isEmpty else { return }

        let firstMeaningfulIdx = rawTrace.entries.firstIndex { $0.blockName.contains("!") }
        let lastMeaningfulIdx = rawTrace.entries.lastIndex { $0.blockName.contains("!") }
        guard let firstMeaningfulIdx, let lastMeaningfulIdx else { return }

        var cleanEntries = Array(rawTrace.entries[firstMeaningfulIdx...lastMeaningfulIdx])

        if let hookTarget, let prologueData,
            firstMeaningfulIdx > 0
        {
            let firstEntry = cleanEntries[0]
            let overwrittenSize = Int(firstEntry.blockAddress - hookTarget)

            if overwrittenSize > 0, overwrittenSize <= prologueData.count {
                var restoreWrites: [RegisterWrite] = []
                if firstMeaningfulIdx >= 2 {
                    let restoreEntry = rawTrace.entries[firstMeaningfulIdx - 2]
                    restoreWrites = deduplicateAndSort(Array(restoreEntry.registerWrites.dropFirst()))
                        .map { RegisterWrite(blockOffset: 0, registerName: $0.registerName, registerIndex: $0.registerIndex, value: $0.value) }
                }

                let trampolineEntry = rawTrace.entries[firstMeaningfulIdx - 1]
                var trampolineWrites = Array(trampolineEntry.registerWrites.dropFirst())
                if trampolineWrites.last?.registerName == "x16" {
                    trampolineWrites.removeLast()
                }
                trampolineWrites = deduplicateAndSort(trampolineWrites)

                let shiftedWrites = Array(firstEntry.registerWrites.dropFirst()).map { write in
                    RegisterWrite(
                        blockOffset: write.blockOffset + overwrittenSize,
                        registerName: write.registerName,
                        registerIndex: write.registerIndex,
                        value: write.value
                    )
                }

                let mergedWrites = restoreWrites + trampolineWrites + shiftedWrites

                var mergedBytesData = Data(prologueData.prefix(overwrittenSize))
                if let realHex = metadata.blocks.first(where: { parseHexAddress($0.address) == firstEntry.blockAddress })?.bytes,
                    let realBytes = hexToData(realHex)
                {
                    mergedBytesData.append(realBytes)
                }

                let bangIdx = firstEntry.blockName.firstIndex(of: "!")!
                let moduleName = firstEntry.blockName[...firstEntry.blockName.index(before: bangIdx)]
                let origOffset = parseHexAddress(
                    String(firstEntry.blockName[firstEntry.blockName.index(after: bangIdx)...]))!
                let mergedName = "\(moduleName)!0x\(String(origOffset - UInt64(overwrittenSize), radix: 16))"

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
            metadata.blocks = metadata.blocks.filter { $0.name.contains("!") }
        }

        traceData = rebuildTraceData(entries: cleanEntries, metadata: metadata)

        if let data = try? JSONEncoder().encode(metadata) {
            metadataJSON = data
        }
    }

    private static func rebuildTraceData(entries: [TraceEntry], metadata: ITraceMetadata) -> Data {
        var out = Data()

        for entry in entries {
            var addr = entry.blockAddress
            out.append(Data(bytes: &addr, count: 8))

            for write in entry.registerWrites {
                guard write.registerIndex < metadata.regSpecs.count else { continue }
                let size = metadata.regSpecs[write.registerIndex].size
                var value = write.value
                out.append(Data(bytes: &value, count: min(size, 8)))
                if size > 8 {
                    out.append(Data(repeating: 0, count: size - 8))
                }
            }
        }

        return out
    }

    private static func deduplicateAndSort(_ writes: [RegisterWrite]) -> [RegisterWrite] {
        var lastByIndex: [Int: RegisterWrite] = [:]
        for w in writes { lastByIndex[w.registerIndex] = w }
        return lastByIndex.values.sorted { $0.registerIndex < $1.registerIndex }
    }

    // MARK: - Helpers

    private static func computeRegisterStates(_ entries: [TraceEntry]) -> [RegisterState] {
        var current: [Int: UInt64] = [:]
        var states: [RegisterState] = []
        states.reserveCapacity(entries.count)

        for entry in entries {
            var changed = Set<Int>()
            for write in entry.registerWrites {
                current[write.registerIndex] = write.value
                changed.insert(write.registerIndex)
            }
            states.append(RegisterState(values: current, changed: changed))
        }

        return states
    }

    private static func groupIntoFunctionCalls(_ entries: [TraceEntry]) -> [TraceFunctionCall] {
        guard !entries.isEmpty else { return [] }

        var calls: [TraceFunctionCall] = []
        var currentSymbol = baseSymbol(of: entries[0].blockName)
        var startIndex = 0

        for i in 1..<entries.count {
            let symbol = baseSymbol(of: entries[i].blockName)
            if symbol != currentSymbol {
                calls.append(TraceFunctionCall(
                    functionName: currentSymbol,
                    startIndex: startIndex,
                    endIndex: i
                ))
                currentSymbol = symbol
                startIndex = i
            }
        }

        calls.append(TraceFunctionCall(
            functionName: currentSymbol,
            startIndex: startIndex,
            endIndex: entries.count
        ))

        return calls
    }

    public static func baseSymbol(of name: String) -> String {
        if let plus = name.firstIndex(of: "+") {
            return String(name[..<plus])
        }
        return name
    }

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

    public static func parseHexAddress(_ s: String) -> UInt64? {
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
