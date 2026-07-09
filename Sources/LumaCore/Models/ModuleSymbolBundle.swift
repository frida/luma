import Foundation

public struct ModuleSymbolBundle: Sendable {
    public var exports: [Export]
    public var imports: [Import]
    public var symbols: [Symbol]

    public init(exports: [Export] = [], imports: [Import] = [], symbols: [Symbol] = []) {
        self.exports = exports
        self.imports = imports
        self.symbols = symbols
    }

    public enum SymbolKind: String, Sendable, Hashable {
        case function
        case variable
    }

    public struct Export: Sendable, Hashable, Identifiable {
        public var id: String { "\(name)@0x\(String(address, radix: 16))" }
        public let kind: SymbolKind
        public let name: String
        public let address: UInt64

        public init(kind: SymbolKind, name: String, address: UInt64) {
            self.kind = kind
            self.name = name
            self.address = address
        }
    }

    public struct Import: Sendable, Hashable, Identifiable {
        public var id: String { "\(module ?? "?")!\(name)@0x\(String(address ?? 0, radix: 16))" }
        public let kind: SymbolKind?
        public let name: String
        public let module: String?
        public let address: UInt64?
        public let slot: UInt64?

        public init(kind: SymbolKind?, name: String, module: String?, address: UInt64?, slot: UInt64?) {
            self.kind = kind
            self.name = name
            self.module = module
            self.address = address
            self.slot = slot
        }
    }

    public struct Symbol: Sendable, Hashable, Identifiable {
        public var id: String { "\(name)@0x\(String(address, radix: 16))" }
        public let name: String
        public let type: String
        public let address: UInt64
        public let isGlobal: Bool
        public let size: Int?
        public let sectionID: String?
        public let sectionProtection: String?

        public init(
            name: String,
            type: String,
            address: UInt64,
            isGlobal: Bool,
            size: Int?,
            sectionID: String?,
            sectionProtection: String?
        ) {
            self.name = name
            self.type = type
            self.address = address
            self.isGlobal = isGlobal
            self.size = size
            self.sectionID = sectionID
            self.sectionProtection = sectionProtection
        }

        public var isCode: Bool {
            if type == "undefined" { return false }
            if type == "function" { return true }
            if let prot = sectionProtection, prot.contains("x") { return true }
            return false
        }

        public var isData: Bool {
            type == "object" || type == "common" || type == "tls"
        }
    }
}

extension ModuleSymbolBundle {
    static func parseAddress(_ s: String?) -> UInt64? {
        guard let s else { return nil }
        let trimmed = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        return UInt64(trimmed, radix: 16)
    }

    public static func fromJSON(_ obj: [String: Any]) -> ModuleSymbolBundle {
        let exportDicts = (obj["exports"] as? [[String: Any]]) ?? []
        let importDicts = (obj["imports"] as? [[String: Any]]) ?? []
        let symbolDicts = (obj["symbols"] as? [[String: Any]]) ?? []

        let exports: [Export] = exportDicts.compactMap { dict in
            guard let typeRaw = dict["type"] as? String,
                let kind = SymbolKind(rawValue: typeRaw),
                let name = dict["name"] as? String,
                let address = parseAddress(dict["address"] as? String)
            else { return nil }
            return Export(kind: kind, name: name, address: address)
        }

        let imports: [Import] = importDicts.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let kind = (dict["type"] as? String).flatMap(SymbolKind.init(rawValue:))
            return Import(
                kind: kind,
                name: name,
                module: dict["module"] as? String,
                address: parseAddress(dict["address"] as? String),
                slot: parseAddress(dict["slot"] as? String)
            )
        }

        let symbols: [Symbol] = symbolDicts.compactMap { dict in
            guard let name = dict["name"] as? String,
                let type = dict["type"] as? String,
                let address = parseAddress(dict["address"] as? String),
                let isGlobal = dict["isGlobal"] as? Bool
            else { return nil }
            return Symbol(
                name: name,
                type: type,
                address: address,
                isGlobal: isGlobal,
                size: dict["size"] as? Int,
                sectionID: dict["sectionID"] as? String,
                sectionProtection: dict["sectionProtection"] as? String
            )
        }

        return ModuleSymbolBundle(
            exports: exports.sorted { $0.name < $1.name },
            imports: imports.sorted { $0.name < $1.name },
            symbols: symbols.sorted { $0.name < $1.name }
        )
    }
}
