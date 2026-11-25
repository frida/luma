import Foundation
import SwiftyPharo

/// What a Pharo result looked like when it was evaluated, kept so a notebook
/// still shows its results with no VM running — offline, or on a peer that
/// received the entry over collaboration.
public struct PharoSnapshot: Codable, Sendable, Equatable {
    public var printString: String
    public var className: String
    public var views: [View]

    public struct View: Codable, Sendable, Equatable {
        public var title: String
        public var methodSelector: String
        public var content: Content
        public var priority: Double

        public enum Content: Codable, Sendable, Equatable {
            case items(kept: [[Cell]], total: Int)
            case text(String)
            case graph(PharoGraph)
            case chart(PharoChart)
            /// Drawn by the host from a scene it holds, named by handle.
            case canvas(scene: Int)
            case empty
        }

        /// Mirrors what the image sends for a row's cell, so a captured view
        /// keeps its pictures as well as its words.
        public struct Cell: Codable, Sendable, Equatable {
            public var text: String?
            public var png: Data?

            public init(text: String?, png: Data?) {
                self.text = text
                self.png = png
            }

            private enum CodingKeys: String, CodingKey {
                case text
                case png
            }

            public init(from decoder: Decoder) throws {
                try decoder.requireKnownKeys(CodingKeys.self)
                let c = try decoder.container(keyedBy: CodingKeys.self)
                text = try c.decodeIfPresent(String.self, forKey: .text)
                png = try c.decodeIfPresent(Data.self, forKey: .png)
            }
        }

        public init(title: String, methodSelector: String, content: Content, priority: Double) {
            self.title = title
            self.methodSelector = methodSelector
            self.content = content
            self.priority = priority
        }

        private enum CodingKeys: String, CodingKey {
            case title
            case methodSelector = "method_selector"
            case content
            case priority
        }

        public init(from decoder: Decoder) throws {
            try decoder.requireKnownKeys(CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            methodSelector = try c.decode(String.self, forKey: .methodSelector)
            content = try c.decode(Content.self, forKey: .content)
            priority = try c.decode(Double.self, forKey: .priority)
        }
    }

    /// The live inspector pages the rest back in when a VM is around.
    static let retainedItemCount = 100

    public init(printString: String, className: String, views: [View]) {
        self.printString = printString
        self.className = className
        self.views = views
    }

    private enum CodingKeys: String, CodingKey {
        case printString = "print_string"
        case className = "class_name"
        case views
    }

    public init(from decoder: Decoder) throws {
        try decoder.requireKnownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printString = try c.decode(String.self, forKey: .printString)
        className = try c.decode(String.self, forKey: .className)
        views = try c.decode([View].self, forKey: .views)
    }
}

extension PharoSnapshot.View.Content {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case items
        case text
        case graph
        case chart
        case canvas
        case empty
    }

    private enum ItemsKeys: String, CodingKey {
        case kept
        case total
    }

    private enum TextKeys: String, CodingKey {
        case text
    }

    private enum CanvasKeys: String, CodingKey {
        case scene
    }

    public init(from decoder: Decoder) throws {
        let (c, kind) = try decoder.soleKey(CodingKeys.self, of: "a view's content")
        switch kind {
        case .items:
            let items = try c.strictlyNested(ItemsKeys.self, forKey: .items)
            self = .items(kept: try items.decode([[PharoSnapshot.View.Cell]].self, forKey: .kept), total: try items.decode(Int.self, forKey: .total))
        case .text:
            self = .text(try c.strictlyNested(TextKeys.self, forKey: .text).decode(String.self, forKey: .text))
        case .graph:
            self = .graph(try c.decode(GraphForm.self, forKey: .graph).graph())
        case .chart:
            self = .chart(try c.decode(ChartForm.self, forKey: .chart).chart())
        case .canvas:
            self = .canvas(scene: try c.strictlyNested(CanvasKeys.self, forKey: .canvas).decode(Int.self, forKey: .scene))
        case .empty:
            _ = try c.strictlyNested(TextKeys.self, forKey: .empty, knowing: [])
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .items(let kept, let total):
            var items = c.nestedContainer(keyedBy: ItemsKeys.self, forKey: .items)
            try items.encode(kept, forKey: .kept)
            try items.encode(total, forKey: .total)
        case .text(let text):
            var nested = c.nestedContainer(keyedBy: TextKeys.self, forKey: .text)
            try nested.encode(text, forKey: .text)
        case .graph(let graph):
            try c.encode(GraphForm(graph), forKey: .graph)
        case .chart(let chart):
            try c.encode(ChartForm(chart), forKey: .chart)
        case .canvas(let scene):
            var nested = c.nestedContainer(keyedBy: CanvasKeys.self, forKey: .canvas)
            try nested.encode(scene, forKey: .scene)
        case .empty:
            _ = c.nestedContainer(keyedBy: TextKeys.self, forKey: .empty)
        }
    }
}

private struct GraphForm: Codable {
    let layout: String
    let nodes: [NodeForm]
    let edges: [EdgeForm]

    struct NodeForm: Codable {
        let label: String

        private enum CodingKeys: String, CodingKey {
            case label
        }

        init(label: String) {
            self.label = label
        }

        init(from decoder: Decoder) throws {
            try decoder.requireKnownKeys(CodingKeys.self)
            label = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .label)
        }
    }

    struct EdgeForm: Codable {
        let from: Int
        let to: Int

        private enum CodingKeys: String, CodingKey {
            case from
            case to
        }

        init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }

        init(from decoder: Decoder) throws {
            try decoder.requireKnownKeys(CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            from = try c.decode(Int.self, forKey: .from)
            to = try c.decode(Int.self, forKey: .to)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case layout
        case nodes
        case edges
    }

    init(_ graph: PharoGraph) {
        layout = graph.layout
        nodes = graph.nodes.map { NodeForm(label: $0.label) }
        edges = graph.edges.map { EdgeForm(from: $0.from, to: $0.to) }
    }

    init(from decoder: Decoder) throws {
        try decoder.requireKnownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decode(String.self, forKey: .layout)
        nodes = try c.decode([NodeForm].self, forKey: .nodes)
        edges = try c.decode([EdgeForm].self, forKey: .edges)
    }

    func graph() throws -> PharoGraph {
        try pharoValue(of: self)
    }
}

private struct ChartForm: Codable {
    let scaleX: String
    let scaleY: String
    let titleX: String
    let titleY: String
    let series: [SeriesForm]

    struct SeriesForm: Codable {
        let kind: String
        let orientation: String
        let points: [PointForm]

        private enum CodingKeys: String, CodingKey {
            case kind
            case orientation
            case points
        }

        init(_ series: PharoChartSeries) {
            kind = series.kind
            orientation = series.orientation
            points = series.points.map(PointForm.init)
        }

        init(from decoder: Decoder) throws {
            try decoder.requireKnownKeys(CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            orientation = try c.decode(String.self, forKey: .orientation)
            points = try c.decode([PointForm].self, forKey: .points)
        }
    }

    struct PointForm: Codable {
        let label: String
        let x: Double
        let y: Double

        private enum CodingKeys: String, CodingKey {
            case label
            case x
            case y
        }

        init(_ point: PharoChartPoint) {
            label = point.label
            x = point.x
            y = point.y
        }

        init(from decoder: Decoder) throws {
            try decoder.requireKnownKeys(CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case scaleX = "scale_x"
        case scaleY = "scale_y"
        case titleX = "title_x"
        case titleY = "title_y"
        case series
    }

    init(_ chart: PharoChart) {
        scaleX = chart.scaleX
        scaleY = chart.scaleY
        titleX = chart.titleX
        titleY = chart.titleY
        series = chart.series.map(SeriesForm.init)
    }

    init(from decoder: Decoder) throws {
        try decoder.requireKnownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scaleX = try c.decode(String.self, forKey: .scaleX)
        scaleY = try c.decode(String.self, forKey: .scaleY)
        titleX = try c.decode(String.self, forKey: .titleX)
        titleY = try c.decode(String.self, forKey: .titleY)
        series = try c.decode([SeriesForm].self, forKey: .series)
    }

    func chart() throws -> PharoChart {
        try pharoValue(of: self)
    }
}

private func pharoValue<Value: Decodable>(of form: some Encodable) throws -> Value {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Value.self, from: JSONEncoder().encode(form))
}

extension PharoSnapshot {
    public static func capture(of object: PharoObject, using runtime: PharoRuntime) async throws -> PharoSnapshot {
        var views: [View] = []

        for declaration in try await runtime.views(of: object) {
            views.append(
                View(
                    title: declaration.title,
                    methodSelector: declaration.methodSelector,
                    content: try await content(of: declaration, in: object, using: runtime),
                    priority: declaration.priority
                )
            )
        }

        return PharoSnapshot(printString: object.printString, className: object.className, views: views)
    }

    private static func content(
        of declaration: PharoViewDeclaration,
        in object: PharoObject,
        using runtime: PharoRuntime
    ) async throws -> View.Content {
        if let text = declaration.text {
            return .text(text)
        }
        if let graph = declaration.graph {
            return .graph(graph)
        }
        if let chart = declaration.chart {
            return .chart(chart)
        }
        if let canvas = declaration.canvas {
            return .canvas(scene: canvas.scene)
        }

        let page = try await runtime.items(
            of: object,
            view: declaration.methodSelector,
            from: 1,
            count: retainedItemCount
        )
        if page.total == 0 {
            return .empty
        }
        let kept = page.items.map { row in
            row.map { View.Cell(text: $0.text, png: $0.png) }
        }
        return .items(kept: kept, total: page.total)
    }
}
