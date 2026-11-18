import Foundation

public struct InstrumentWidget: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: Kind
    public var persistence: Persistence

    public init(id: String, name: String, kind: Kind, persistence: Persistence = .none) {
        self.id = id
        self.name = name
        self.kind = kind
        self.persistence = persistence
    }

    public enum Persistence: String, Codable, Sendable, CaseIterable {
        case none
        case session

        public var label: String {
            switch self {
            case .none: return "None"
            case .session: return "Session"
            }
        }
    }

    public enum Kind: Sendable, Equatable {
        case counter(CounterConfig)
        case histogram(HistogramConfig)
        case graph(GraphConfig)
        case list(ListConfig)
        case table(TableConfig)
        case hex(HexConfig)
        case console(ConsoleConfig)
    }

    public struct CounterConfig: Codable, Sendable, Equatable {
        public var unit: String?

        public init(unit: String? = nil) {
            self.unit = unit
        }
    }

    public struct HistogramConfig: Codable, Sendable, Equatable {
        public static let defaultMaxBuckets: Int = 100

        public var maxBuckets: Int

        public init(maxBuckets: Int = Self.defaultMaxBuckets) {
            self.maxBuckets = maxBuckets
        }
    }

    public struct GraphConfig: Codable, Sendable, Equatable {
        public static let defaultMaxPoints: Int = 5_000

        public var series: [Series]
        public var maxPoints: Int

        public init(series: [Series] = [], maxPoints: Int = Self.defaultMaxPoints) {
            self.series = series
            self.maxPoints = maxPoints
        }
    }

    public struct Series: Codable, Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct ListConfig: Codable, Sendable, Equatable {
        public static let defaultMaxItems: Int = 1_000

        public var actions: [Action]
        public var maxItems: Int

        public init(actions: [Action] = [], maxItems: Int = Self.defaultMaxItems) {
            self.actions = actions
            self.maxItems = maxItems
        }
    }

    public struct TableConfig: Codable, Sendable, Equatable {
        public static let defaultMaxRows: Int = 1_000

        public var columns: [Column]
        public var actions: [Action]
        public var maxRows: Int

        public init(columns: [Column] = [], actions: [Action] = [], maxRows: Int = Self.defaultMaxRows) {
            self.columns = columns
            self.actions = actions
            self.maxRows = maxRows
        }
    }

    public struct Column: Codable, Identifiable, Sendable, Equatable {
        public enum Alignment: String, Codable, Sendable, CaseIterable {
            case leading
            case trailing
        }

        public var id: String
        public var name: String
        public var alignment: Alignment

        public init(id: String, name: String, alignment: Alignment = .leading) {
            self.id = id
            self.name = name
            self.alignment = alignment
        }
    }

    public struct HexConfig: Codable, Sendable, Equatable {
        public static let defaultMaxBytes: Int = 16_384

        public var maxBytes: Int

        public init(maxBytes: Int = Self.defaultMaxBytes) {
            self.maxBytes = maxBytes
        }
    }

    public struct ConsoleConfig: Codable, Sendable, Equatable {
        public static let defaultMaxEntries: Int = 1_000

        public var prompt: String?
        public var placeholder: String?
        public var runButtonLabel: String?
        public var maxEntries: Int

        public init(
            prompt: String? = nil,
            placeholder: String? = nil,
            runButtonLabel: String? = nil,
            maxEntries: Int = Self.defaultMaxEntries
        ) {
            self.prompt = prompt
            self.placeholder = placeholder
            self.runButtonLabel = runButtonLabel
            self.maxEntries = maxEntries
        }
    }

    public struct Action: Codable, Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }
}

extension InstrumentWidget {
    private static let ownWireKeys = ["id", "name", "persistence"]

    public func toWireJSON() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var own = try! JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        let kind = own.removeValue(forKey: "kind") as! [String: Any]
        var wire = kind["config"] as! [String: Any]
        wire.merge(own) { _, own in own }
        wire["kind"] = kind["kind"]
        return wire
    }

    public static func fromWireJSON(_ wire: [String: Any]) -> InstrumentWidget? {
        guard let kind = wire["kind"] as? String else { return nil }
        var nested = wire.filter { ownWireKeys.contains($0.key) }
        nested["kind"] = [
            "kind": kind,
            "config": wire.filter { !ownWireKeys.contains($0.key) && $0.key != "kind" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: nested) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(InstrumentWidget.self, from: data)
    }
}

extension InstrumentWidget.Kind: Codable {
    private enum CodingKeys: String, CodingKey { case kind, config }
    private enum Tag: String, Codable { case counter, histogram, graph, list, table, hex, console }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .kind) {
        case .counter:
            self = .counter(try c.decode(InstrumentWidget.CounterConfig.self, forKey: .config))
        case .histogram:
            self = .histogram(try c.decode(InstrumentWidget.HistogramConfig.self, forKey: .config))
        case .graph:
            self = .graph(try c.decode(InstrumentWidget.GraphConfig.self, forKey: .config))
        case .list:
            self = .list(try c.decode(InstrumentWidget.ListConfig.self, forKey: .config))
        case .table:
            self = .table(try c.decode(InstrumentWidget.TableConfig.self, forKey: .config))
        case .hex:
            self = .hex(try c.decode(InstrumentWidget.HexConfig.self, forKey: .config))
        case .console:
            self = .console(try c.decode(InstrumentWidget.ConsoleConfig.self, forKey: .config))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .counter(let cfg):
            try c.encode(Tag.counter, forKey: .kind)
            try c.encode(cfg, forKey: .config)
        case .histogram(let h):
            try c.encode(Tag.histogram, forKey: .kind)
            try c.encode(h, forKey: .config)
        case .graph(let g):
            try c.encode(Tag.graph, forKey: .kind)
            try c.encode(g, forKey: .config)
        case .list(let l):
            try c.encode(Tag.list, forKey: .kind)
            try c.encode(l, forKey: .config)
        case .table(let t):
            try c.encode(Tag.table, forKey: .kind)
            try c.encode(t, forKey: .config)
        case .hex(let h):
            try c.encode(Tag.hex, forKey: .kind)
            try c.encode(h, forKey: .config)
        case .console(let cfg):
            try c.encode(Tag.console, forKey: .kind)
            try c.encode(cfg, forKey: .config)
        }
    }
}
