import Foundation

public struct InstrumentWidget: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var kind: Kind
    public var actions: [Action]
    public var persistence: Persistence

    public var title: String? {
        name
    }

    public var label: String {
        name ?? id
    }

    public var hasHeader: Bool {
        title != nil || !actions.isEmpty || kind.hasRows
    }

    public init(id: String, name: String?, kind: Kind, actions: [Action] = [], persistence: Persistence = .none) {
        self.id = id
        self.name = name
        self.kind = kind
        self.actions = actions
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
        case view(ViewConfig)
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

        public var rowActions: [Action]
        public var rowActivation: Action?
        public var rowSelection: Action?
        public var maxItems: Int

        public init(
            rowActions: [Action] = [], rowActivation: Action? = nil, rowSelection: Action? = nil, maxItems: Int = Self.defaultMaxItems
        ) {
            self.rowActions = rowActions
            self.rowActivation = rowActivation
            self.rowSelection = rowSelection
            self.maxItems = maxItems
        }
    }

    public struct TableConfig: Codable, Sendable, Equatable {
        public static let defaultMaxRows: Int = 1_000

        public var columns: [Column]
        public var rowActions: [Action]
        public var rowActivation: Action?
        public var rowSelection: Action?
        public var maxRows: Int

        public init(
            columns: [Column] = [], rowActions: [Action] = [], rowActivation: Action? = nil, rowSelection: Action? = nil,
            maxRows: Int = Self.defaultMaxRows
        ) {
            self.columns = columns
            self.rowActions = rowActions
            self.rowActivation = rowActivation
            self.rowSelection = rowSelection
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

    public struct ViewConfig: Codable, Sendable, Equatable {
        public static let defaultHeight: Int = 360

        public var className: String
        public var height: Int

        public init(className: String, height: Int = Self.defaultHeight) {
            self.className = className
            self.height = height
        }

        private enum CodingKeys: String, CodingKey {
            case className = "class"
            case height
        }

        public init(from decoder: Decoder) throws {
            try decoder.refuseUnknownKeys(CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            className = try c.decode(String.self, forKey: .className)
            height = try c.decodeIfPresent(Int.self, forKey: .height) ?? Self.defaultHeight
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

extension InstrumentWidget.Kind {
    public var isView: Bool {
        if case .view = self { return true }
        return false
    }

    public var hasRows: Bool {
        switch self {
        case .list, .table: return true
        default: return false
        }
    }

    public var rowActions: [InstrumentWidget.Action] {
        switch self {
        case .list(let cfg): return cfg.rowActions
        case .table(let cfg): return cfg.rowActions
        default: return []
        }
    }

    public var rowActivation: InstrumentWidget.Action? {
        switch self {
        case .list(let cfg): return cfg.rowActivation
        case .table(let cfg): return cfg.rowActivation
        default: return nil
        }
    }

    public var rowSelection: InstrumentWidget.Action? {
        switch self {
        case .list(let cfg): return cfg.rowSelection
        case .table(let cfg): return cfg.rowSelection
        default: return nil
        }
    }

    public var rowInvocations: [InstrumentWidget.Action] {
        rowActions + [rowActivation, rowSelection].compactMap { $0 }
    }
}

extension InstrumentWidget {
    public static let maxCount = 32
    public static let maxIDLength = 64
    public static let maxNameLength = 120
    public static let maxActions = 32

    public struct Problem: Error, Sendable, Equatable {
        public enum Step: Sendable, Equatable {
            case key(String)
            case index(Int)
        }

        public let path: [Step]
        public let text: String
    }

    public var repeatedActionID: String? {
        var seen: Set<String> = []
        return (actions + kind.rowInvocations).map(\.id).first { !seen.insert($0).inserted }
    }

    public var problem: Problem? {
        if let text = Self.idProblem(id) {
            return Problem(path: [.key("id")], text: text)
        }
        if let name, let text = Self.nameProblem(name, absence: "leave the key out for a widget with no title") {
            return Problem(path: [.key("name")], text: text)
        }
        let declared: [(path: [Problem.Step], actions: [Action])] = [
            ([.key("actions")], actions),
            ([.key("config"), .key("rowActions")], kind.rowActions),
        ]
        for (path, list) in declared {
            if let problem = Self.problem(in: list, at: path) {
                return problem
            }
        }
        let triggered: [(path: [Problem.Step], action: Action)] = [
            ([.key("config"), .key("rowActivation")], kind.rowActivation),
            ([.key("config"), .key("rowSelection")], kind.rowSelection),
        ].compactMap { path, action in action.map { (path, $0) } }
        if let problem = triggered.lazy.compactMap({ Self.problem(in: $0.action, at: $0.path) }).first {
            return problem
        }
        var seen: Set<String> = []
        let located =
            declared.flatMap { entry in entry.actions.indices.map { (entry.path + [.index($0)], entry.actions[$0].id) } }
            + triggered.map { ($0.path, $0.action.id) }
        guard let (path, id) = located.first(where: { !seen.insert($0.1).inserted }) else { return nil }
        return Problem(path: path + [.key("id")], text: "\"\(id)\" is already the id of another action of this widget")
    }

    public static func countProblem(_ count: Int) -> String? {
        count > maxCount ? "has \(count) widgets; at most \(maxCount) are allowed" : nil
    }

    public static func repeatedIDProblem(in widgets: [InstrumentWidget]) -> Problem? {
        var seen: Set<String> = []
        guard let index = widgets.firstIndex(where: { !seen.insert($0.id).inserted }) else { return nil }
        return Problem(path: [.index(index), .key("id")], text: "\"\(widgets[index].id)\" is already the id of another widget")
    }

    private static func problem(in list: [Action], at path: [Problem.Step]) -> Problem? {
        guard list.count <= maxActions else {
            return Problem(path: path, text: "has \(list.count) actions; at most \(maxActions) are allowed")
        }
        return list.indices.lazy.compactMap { problem(in: list[$0], at: path + [.index($0)]) }.first
    }

    private static func problem(in action: Action, at path: [Problem.Step]) -> Problem? {
        if let text = idProblem(action.id) {
            return Problem(path: path + [.key("id")], text: text)
        }
        if let text = nameProblem(action.name, absence: "an action needs one") {
            return Problem(path: path + [.key("name")], text: text)
        }
        return nil
    }

    private static func idProblem(_ id: String) -> String? {
        if id.isEmpty {
            return "must not be empty"
        }
        return id.count > maxIDLength ? "is longer than \(maxIDLength) characters" : nil
    }

    private static func nameProblem(_ name: String, absence: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "must not be empty; \(absence)"
        }
        return name.count > maxNameLength ? "is longer than \(maxNameLength) characters" : nil
    }
}

extension InstrumentWidget {
    private static let ownWireKeys = ["id", "name", "actions", "persistence"]

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
    private enum Tag: String, Codable { case counter, histogram, graph, list, table, hex, console, view }

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
        case .view:
            self = .view(try c.decode(InstrumentWidget.ViewConfig.self, forKey: .config))
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
        case .view(let cfg):
            try c.encode(Tag.view, forKey: .kind)
            try c.encode(cfg, forKey: .config)
        }
    }
}

extension InstrumentWidget {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name),
            kind: try c.decode(Kind.self, forKey: .kind),
            actions: try c.decodeIfPresent([Action].self, forKey: .actions) ?? [],
            persistence: try c.decodeIfPresent(Persistence.self, forKey: .persistence) ?? .none)
    }
}

extension InstrumentWidget.CounterConfig {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(unit: try c.decodeIfPresent(String.self, forKey: .unit))
    }
}

extension InstrumentWidget.HistogramConfig {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxBuckets: try c.decodeIfPresent(Int.self, forKey: .maxBuckets) ?? Self.defaultMaxBuckets)
    }
}

extension InstrumentWidget.GraphConfig {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            series: try c.decode([InstrumentWidget.Series].self, forKey: .series),
            maxPoints: try c.decodeIfPresent(Int.self, forKey: .maxPoints) ?? Self.defaultMaxPoints)
    }
}

extension InstrumentWidget {
    fileprivate static let renamedRowActionsKey = ["actions": "rowActions"]
}

extension InstrumentWidget.ListConfig {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self, renamed: InstrumentWidget.renamedRowActionsKey)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rowActions: try c.decodeIfPresent([InstrumentWidget.Action].self, forKey: .rowActions) ?? [],
            rowActivation: try c.decodeIfPresent(InstrumentWidget.Action.self, forKey: .rowActivation),
            rowSelection: try c.decodeIfPresent(InstrumentWidget.Action.self, forKey: .rowSelection),
            maxItems: try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? Self.defaultMaxItems)
    }
}

extension InstrumentWidget.TableConfig {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self, renamed: InstrumentWidget.renamedRowActionsKey)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            columns: try c.decode([InstrumentWidget.Column].self, forKey: .columns),
            rowActions: try c.decodeIfPresent([InstrumentWidget.Action].self, forKey: .rowActions) ?? [],
            rowActivation: try c.decodeIfPresent(InstrumentWidget.Action.self, forKey: .rowActivation),
            rowSelection: try c.decodeIfPresent(InstrumentWidget.Action.self, forKey: .rowSelection),
            maxRows: try c.decodeIfPresent(Int.self, forKey: .maxRows) ?? Self.defaultMaxRows)
    }
}

extension InstrumentWidget.Series {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name))
    }
}

extension InstrumentWidget.Action {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name))
    }
}

extension InstrumentWidget.Column {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            alignment: try c.decodeIfPresent(Alignment.self, forKey: .alignment) ?? .leading)
    }
}

extension InstrumentWidget.HexConfig {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxBytes: try c.decodeIfPresent(Int.self, forKey: .maxBytes) ?? Self.defaultMaxBytes)
    }
}

extension InstrumentWidget.ConsoleConfig {
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            prompt: try c.decodeIfPresent(String.self, forKey: .prompt),
            placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
            runButtonLabel: try c.decodeIfPresent(String.self, forKey: .runButtonLabel),
            maxEntries: try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? Self.defaultMaxEntries)
    }
}
