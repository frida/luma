public struct ThreadDelta: Sendable {
    public let added: [ProcessThread]
    public let removed: [UInt]
    public let renamed: [Rename]

    public init(added: [ProcessThread] = [], removed: [UInt] = [], renamed: [Rename] = []) {
        self.added = added
        self.removed = removed
        self.renamed = renamed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && renamed.isEmpty }

    public struct Rename: Sendable, Hashable {
        public let id: UInt
        public let name: String?

        public init(id: UInt, name: String?) {
            self.id = id
            self.name = name
        }
    }

    public func applied(to base: [ProcessThread]?) -> [ProcessThread] {
        var result = base ?? []
        let removedSet = Set(removed)
        if !removedSet.isEmpty {
            result.removeAll { removedSet.contains($0.id) }
        }
        result.append(contentsOf: added)
        for r in renamed {
            if let i = result.firstIndex(where: { $0.id == r.id }) {
                result[i].name = r.name
            }
        }
        return result
    }
}

extension Array where Element == ProcessThread {
    public func sidebarHighlights(
        selectedID: ProcessThread.ID?,
        limit: Int = SidebarHighlights.defaultLimit
    ) -> [ProcessThread] {
        guard let main = first else { return [] }
        let rest = dropFirst()
        let named = rest.filter { $0.name != nil }
        let unnamed = rest.filter { $0.name == nil }
        let peers = (named + unnamed).prefix(Swift.max(0, limit - 1))
        let featured = [main] + peers
        return featured.withSelected(selectedID, from: self, limit: limit)
    }
}

public struct ProcessThread: Hashable, Identifiable, Codable, Sendable {
    public var id: UInt
    public var name: String?
    public var entrypoint: Entrypoint?

    public init(id: UInt, name: String? = nil, entrypoint: Entrypoint? = nil) {
        self.id = id
        self.name = name
        self.entrypoint = entrypoint
    }

    public struct Entrypoint: Hashable, Codable, Sendable {
        public let routine: UInt64
        public let parameter: UInt64?

        public init(routine: UInt64, parameter: UInt64? = nil) {
            self.routine = routine
            self.parameter = parameter
        }
    }

    public func toJSON() -> [String: Any] {
        var obj: [String: Any] = ["id": Int(id)]
        if let name { obj["name"] = name }
        if let entrypoint {
            var ep: [String: Any] = ["routine": String(format: "0x%llx", entrypoint.routine)]
            if let parameter = entrypoint.parameter {
                ep["parameter"] = String(format: "0x%llx", parameter)
            }
            obj["entrypoint"] = ep
        }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any]) -> ProcessThread? {
        guard let rawID = obj["id"] as? Int else { return nil }
        let name = obj["name"] as? String
        var entry: Entrypoint?
        if let ep = obj["entrypoint"] as? [String: Any],
            let routineStr = ep["routine"] as? String,
            let routine = HexAddress.parse(routineStr)
        {
            let param = (ep["parameter"] as? String).flatMap(HexAddress.parse)
            entry = Entrypoint(routine: routine, parameter: param)
        }
        return ProcessThread(id: UInt(rawID), name: name, entrypoint: entry)
    }
}

public struct ThreadSnapshot: Sendable {
    public var id: UInt
    public var name: String?
    public var state: String
    public var registers: [Register]

    public struct Register: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let rawValue: String

        public init(name: String, rawValue: String) {
            self.name = name
            self.rawValue = rawValue
        }

        public var pointerValue: UInt64? {
            let trimmed = rawValue.hasPrefix("0x") ? String(rawValue.dropFirst(2)) : rawValue
            return UInt64(trimmed, radix: 16)
        }
    }

    public init(id: UInt, name: String?, state: String, registers: [Register]) {
        self.id = id
        self.name = name
        self.state = state
        self.registers = registers
    }

    public static func fromJSON(_ obj: [String: Any]) -> ThreadSnapshot? {
        guard let rawID = obj["id"] as? Int,
            let state = obj["state"] as? String,
            let regsAny = obj["registers"] as? [[Any]]
        else { return nil }

        let name = obj["name"] as? String

        var regs: [Register] = []
        regs.reserveCapacity(regsAny.count)
        for entry in regsAny {
            guard entry.count == 2,
                let key = entry[0] as? String,
                let value = entry[1] as? String
            else { continue }
            regs.append(Register(name: key, rawValue: value))
        }

        let order = CpuRegisterLayout.ordered(regs.map(\.name))
        let byName = Dictionary(uniqueKeysWithValues: regs.map { ($0.name, $0) })
        return ThreadSnapshot(id: UInt(rawID), name: name, state: state, registers: order.map { byName[$0]! })
    }
}
