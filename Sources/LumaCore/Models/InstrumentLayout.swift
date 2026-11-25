import Foundation

public struct InstrumentLayout: Codable, Sendable, Equatable {
    public static let maxDepth = 3
    public static let maxRowEntries = 6
    public static let maxColumnEntries = 32
    public static let shareRange = 1...100
    public static let maxRowsRange = 1...1000
    public static let foldBelowRange = 240...4000

    public typealias Path = [Int]
    public typealias Problem = InstrumentWidget.Problem

    public var root: Node

    public init(root: Node) {
        self.root = root
    }

    public static func stack(of widgets: [InstrumentWidget]) -> InstrumentLayout {
        InstrumentLayout(root: .column(widgets.map { .widget($0.id) }))
    }

    public struct Node: Sendable, Equatable {
        public enum Content: Sendable, Equatable {
            case widget(String)
            case row([Node])
            case column([Node])
        }

        public var content: Content
        public var share: Int?
        public var maxRows: Int?
        public var foldBelow: Int?

        public init(_ content: Content, share: Int? = nil, maxRows: Int? = nil, foldBelow: Int? = nil) {
            self.content = content
            self.share = share
            self.maxRows = maxRows
            self.foldBelow = foldBelow
        }

        public static func widget(_ id: String, share: Int? = nil, maxRows: Int? = nil) -> Node {
            Node(.widget(id), share: share, maxRows: maxRows)
        }

        public static func row(_ entries: [Node], share: Int? = nil, foldBelow: Int? = nil) -> Node {
            Node(.row(entries), share: share, foldBelow: foldBelow)
        }

        public static func column(_ entries: [Node], share: Int? = nil) -> Node {
            Node(.column(entries), share: share)
        }

        public var widgetID: String? {
            if case .widget(let id) = content { return id }
            return nil
        }

        public var axis: Axis? {
            switch content {
            case .widget: return nil
            case .row: return .horizontal
            case .column: return .vertical
            }
        }

        public var entries: [Node] {
            get {
                switch content {
                case .widget: return []
                case .row(let entries), .column(let entries): return entries
                }
            }
            set {
                switch content {
                case .widget: break
                case .row: content = .row(newValue)
                case .column: content = .column(newValue)
                }
            }
        }

        public subscript(path: Path) -> Node {
            get {
                path.reduce(self) { node, index in node.entries[index] }
            }
            set {
                guard let first = path.first else {
                    self = newValue
                    return
                }
                var entries = self.entries
                entries[first][Array(path.dropFirst())] = newValue
                self.entries = entries
            }
        }
    }

    public enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
    }

    public enum KeyStyle: Sendable {
        case camelCase
        case snakeCase
    }

    public enum SizeKey: Sendable, CaseIterable {
        case share
        case maxRows
        case foldBelow
    }

    public subscript(path: Path) -> Node {
        root[path]
    }

    public var placedWidgetIDs: [String] {
        root.placements(at: []).map(\.id)
    }

    public func path(of widget: String) -> Path? {
        root.placements(at: []).first { $0.id == widget }?.path
    }

    public func unplaced(in widgets: [InstrumentWidget]) -> [String] {
        let placed = Set(placedWidgetIDs)
        return widgets.map(\.id).filter { !placed.contains($0) }
    }

    public init(json: JSONValue, keys: KeyStyle) throws(Problem) {
        root = try Node(json: json, names: KeyNames(keys), at: [], depth: 0)
    }

    public func json(_ keys: KeyStyle) -> JSONValue {
        root.json(KeyNames(keys))
    }

    public func problem(placing widgets: [InstrumentWidget], keys: KeyStyle, widgetsName: String, layoutName: String) -> Problem? {
        let names = KeyNames(keys)
        let kinds = Dictionary(widgets.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var placedAt: [String: [Problem.Step]] = [:]
        for placement in root.placements(at: []) {
            let steps = Self.steps(to: placement.path, in: root)
            let node = root[placement.path]
            guard let kind = kinds[placement.id] else {
                let at = node.isBare ? steps : steps + [.key(names.widget)]
                return Problem(path: at, text: "\"\(placement.id)\" is not the id of a widget in \(widgetsName)")
            }
            if let first = placedAt[placement.id] {
                return Problem(path: steps, text: "\"\(placement.id)\" is already placed at \(layoutName)\(Self.text(of: first))")
            }
            placedAt[placement.id] = steps
            if node.maxRows != nil, let text = Self.maxRowsKindProblem(kind, id: placement.id, names: names) {
                return Problem(path: steps + [.key(names.maxRows)], text: text)
            }
        }
        guard let unplaced = unplaced(in: widgets).first else { return nil }
        return Problem(path: [], text: "\"\(unplaced)\" is not placed; with a layout, every widget needs a place")
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        let layout: InstrumentLayout
        do throws(Problem) {
            layout = try InstrumentLayout(json: json, keys: .camelCase)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath + error.path.map(ManifestKey.init), debugDescription: error.text))
        }
        self = layout
    }

    public func encode(to encoder: Encoder) throws {
        try json(.camelCase).encode(to: encoder)
    }

    var wireJSON: Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(json(.snakeCase)), options: .fragmentsAllowed)
    }

    static func fromWireJSON(_ raw: Any, placing widgets: [InstrumentWidget]) -> InstrumentLayout? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data),
            let layout = try? InstrumentLayout(json: json, keys: .snakeCase),
            layout.problem(placing: widgets, keys: .snakeCase, widgetsName: "widgets", layoutName: "layout") == nil
        else { return nil }
        return layout
    }

    public static func text(of path: [Problem.Step]) -> String {
        path.map { step in
            switch step {
            case .key(let key): return "." + key
            case .index(let index): return "[\(index)]"
            }
        }.joined()
    }

    static func steps(to path: Path, in root: Node) -> [Problem.Step] {
        var steps: [Problem.Step] = []
        var node = root
        for index in path {
            steps += [.key(node.containerKey!), .index(index)]
            node = node.entries[index]
        }
        return steps
    }

    static func sizeProblem(_ key: SizeKey, _ value: Int, on node: Node, kind: InstrumentWidget.Kind?, keys: KeyStyle) -> String? {
        let names = KeyNames(keys)
        switch key {
        case .share:
            return shareRange.contains(value) ? nil : shareRangeText
        case .maxRows:
            if let text = node.maxRowsPlacementProblem(kind: kind, names: names) {
                return text
            }
            return maxRowsRange.contains(value) ? nil : maxRowsRangeText
        case .foldBelow:
            guard case .row = node.content else { return "\(names.foldBelow) is for rows" }
            return foldBelowRange.contains(value) ? nil : foldBelowRangeText
        }
    }

    static func maxRowsKindProblem(_ kind: InstrumentWidget.Kind, id: String, names: KeyNames) -> String? {
        switch kind {
        case .list, .table: return nil
        default: return "\(names.maxRows) is for tables and lists; \"\(id)\" is \(kind.articledName)"
        }
    }

    static let shapeText = "has to be a widget id, or hold exactly one of \"widget\", \"row\" and \"column\""
    static let emptyText = "must hold at least one widget"
    static let shareRangeText = "has to be a whole number from 1 to 100"
    static let maxRowsRangeText = "has to be a whole number from 1 to 1000"
    static let foldBelowRangeText = "has to be a whole number of points from 240 to 4000"

    static func depthText(_ depth: Int) -> String {
        "nests rows and columns \(depth) deep; at most \(maxDepth) are allowed"
    }

    static func entriesText(_ count: Int, in axis: Axis) -> String {
        switch axis {
        case .horizontal: return "has \(count) entries; a row holds at most \(maxRowEntries)"
        case .vertical: return "has \(count) entries; a column holds at most \(maxColumnEntries)"
        }
    }

    struct Placement {
        let id: String
        let path: Path
    }

    struct KeyNames {
        let widget = "widget"
        let row = "row"
        let column = "column"
        let share = "share"
        let maxRows: String
        let foldBelow: String

        init(_ style: KeyStyle) {
            switch style {
            case .camelCase:
                maxRows = "maxRows"
                foldBelow = "foldBelow"
            case .snakeCase:
                maxRows = "max_rows"
                foldBelow = "fold_below"
            }
        }

        var all: [String] {
            [widget, row, column, share, maxRows, foldBelow]
        }
    }
}

extension InstrumentLayout.Node {
    typealias Problem = InstrumentWidget.Problem
    typealias KeyNames = InstrumentLayout.KeyNames

    init(json: JSONValue, names: KeyNames, at path: [Problem.Step], depth: Int) throws(Problem) {
        switch json {
        case .string(let id):
            self.init(.widget(id))
        case .object(let members):
            try self.init(members: members, names: names, at: path, depth: depth)
        default:
            throw Problem(path: path, text: InstrumentLayout.shapeText)
        }
    }

    private init(members: [String: JSONValue], names: KeyNames, at path: [Problem.Step], depth: Int) throws(Problem) {
        if let unknown = members.keys.filter({ !names.all.contains($0) }).min() {
            throw Problem(path: path + [.key(unknown)], text: "unknown key")
        }
        let contentKeys = [names.widget, names.row, names.column].filter { members[$0] != nil }
        guard contentKeys.count == 1, let contentKey = contentKeys.first else {
            throw Problem(path: path, text: InstrumentLayout.shapeText)
        }
        switch (contentKey, members[contentKey]!) {
        case (names.widget, .string(let id)):
            self.init(.widget(id))
        case (names.row, .array(let entries)):
            let parsed = try Self.entries(entries, axis: .horizontal, names: names, at: path, depth: depth + 1)
            self.init(.row(parsed))
        case (names.column, .array(let entries)):
            let parsed = try Self.entries(entries, axis: .vertical, names: names, at: path, depth: depth + 1)
            self.init(.column(parsed))
        default:
            throw Problem(path: path, text: InstrumentLayout.shapeText)
        }
        share = try Self.number(members[names.share], in: InstrumentLayout.shareRange, at: path + [.key(names.share)],
            text: InstrumentLayout.shareRangeText)
        if members[names.maxRows] != nil, let text = maxRowsPlacementProblem(kind: nil, names: names) {
            throw Problem(path: path + [.key(names.maxRows)], text: text)
        }
        maxRows = try Self.number(members[names.maxRows], in: InstrumentLayout.maxRowsRange, at: path + [.key(names.maxRows)],
            text: InstrumentLayout.maxRowsRangeText)
        if members[names.foldBelow] != nil, axis != .horizontal {
            throw Problem(path: path + [.key(names.foldBelow)], text: "\(names.foldBelow) is for rows")
        }
        foldBelow = try Self.number(members[names.foldBelow], in: InstrumentLayout.foldBelowRange, at: path + [.key(names.foldBelow)],
            text: InstrumentLayout.foldBelowRangeText)
    }

    private static func entries(_ entries: [JSONValue], axis: InstrumentLayout.Axis, names: KeyNames, at path: [Problem.Step], depth: Int)
        throws(Problem) -> [InstrumentLayout.Node]
    {
        if depth > InstrumentLayout.maxDepth {
            throw Problem(path: path, text: InstrumentLayout.depthText(depth))
        }
        let key: Problem.Step = .key(axis == .horizontal ? names.row : names.column)
        if entries.isEmpty {
            throw Problem(path: path + [key], text: InstrumentLayout.emptyText)
        }
        let limit = axis == .horizontal ? InstrumentLayout.maxRowEntries : InstrumentLayout.maxColumnEntries
        if entries.count > limit {
            throw Problem(path: path + [key], text: InstrumentLayout.entriesText(entries.count, in: axis))
        }
        var nodes: [InstrumentLayout.Node] = []
        for (index, entry) in entries.enumerated() {
            var node = try InstrumentLayout.Node(json: entry, names: names, at: path + [key, .index(index)], depth: depth)
            if axis == .horizontal {
                node.dropDefaultRowShare()
            }
            nodes.append(node)
        }
        return nodes
    }

    private static func number(_ value: JSONValue?, in range: ClosedRange<Int>, at path: [Problem.Step], text: String) throws(Problem) -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.rounded() == number,
            Double(range.lowerBound) <= number, number <= Double(range.upperBound)
        else {
            throw Problem(path: path, text: text)
        }
        return Int(number)
    }

    func json(_ names: KeyNames) -> JSONValue {
        var members: [String: JSONValue] = [:]
        switch content {
        case .widget(let id):
            if isBare {
                return .string(id)
            }
            members[names.widget] = .string(id)
        case .row(let entries):
            members[names.row] = .array(entries.map { $0.json(names) })
        case .column(let entries):
            members[names.column] = .array(entries.map { $0.json(names) })
        }
        members[names.share] = share.map { .number(Double($0)) }
        members[names.maxRows] = maxRows.map { .number(Double($0)) }
        members[names.foldBelow] = foldBelow.map { .number(Double($0)) }
        return .object(members)
    }

    var isBare: Bool {
        widgetID != nil && share == nil && maxRows == nil
    }

    var containerKey: String? {
        switch content {
        case .widget: return nil
        case .row: return "row"
        case .column: return "column"
        }
    }

    mutating func dropDefaultRowShare() {
        if widgetID != nil && share == 1 {
            share = nil
        }
    }

    func maxRowsPlacementProblem(kind: InstrumentWidget.Kind?, names: KeyNames) -> String? {
        switch content {
        case .widget(let id): return kind.flatMap { InstrumentLayout.maxRowsKindProblem($0, id: id, names: names) }
        case .row: return "\(names.maxRows) is for tables and lists; this is a row"
        case .column: return "\(names.maxRows) is for tables and lists; this is a column"
        }
    }

    func placements(at path: InstrumentLayout.Path) -> [InstrumentLayout.Placement] {
        if let widgetID {
            return [InstrumentLayout.Placement(id: widgetID, path: path)]
        }
        return entries.indices.flatMap { index in entries[index].placements(at: path + [index]) }
    }
}

extension InstrumentWidget.Kind {
    var articledName: String {
        switch self {
        case .counter: return "a counter"
        case .histogram: return "a histogram"
        case .graph: return "a graph"
        case .list: return "a list"
        case .table: return "a table"
        case .hex: return "a hex view"
        case .console: return "a console"
        case .view: return "a view"
        }
    }
}

extension CustomInstrumentDef {
    public var pageLayout: InstrumentLayout {
        layout ?? .stack(of: widgets)
    }
}
