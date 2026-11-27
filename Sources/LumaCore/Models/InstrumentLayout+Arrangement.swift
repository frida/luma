import Foundation

extension InstrumentLayout {
    public static let defaultRowCap = 12
    public static let foldWidthPerEntry = 280.0

    public struct Metrics: Sendable, Equatable {
        public var spacing: Double
        public var headerHeight: Double
        public var headerSpacing: Double
        public var boxInset: Double
        public var lineHeight: Double
        public var rowHeight: Double
        public var tableHeaderHeight: Double
        public var twoLineRowHeight: Double
        public var counterHeight: Double

        public init(
            spacing: Double = 12,
            headerHeight: Double = 20,
            headerSpacing: Double = 4,
            boxInset: Double = 8,
            lineHeight: Double = 17,
            rowHeight: Double = 24,
            tableHeaderHeight: Double = 24,
            twoLineRowHeight: Double = 40,
            counterHeight: Double = 34
        ) {
            self.spacing = spacing
            self.headerHeight = headerHeight
            self.headerSpacing = headerSpacing
            self.boxInset = boxInset
            self.lineHeight = lineHeight
            self.rowHeight = rowHeight
            self.tableHeaderHeight = tableHeaderHeight
            self.twoLineRowHeight = twoLineRowHeight
            self.counterHeight = counterHeight
        }

        public static let standard = Metrics()
    }

    public struct Frame: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Arrangement: Sendable, Equatable {
        public var width: Double
        public var height: Double
        public var scrolls: Bool
        public var frames: [String: Frame]
        public var containerFrames: [Path: Frame]
        public var foldedRows: Set<Path>
    }

    public func arranged(
        widgets: [InstrumentWidget],
        width: Double,
        height: Double,
        rowCounts: [String: Int] = [:],
        subtitledRowCounts: [String: Int] = [:],
        metrics: Metrics = .standard
    ) -> Arrangement {
        var arranger = Arranger(
            widgets: widgets, rowCounts: rowCounts, subtitledRowCounts: subtitledRowCounts, metrics: metrics, pageWidth: width.rounded(.down))
        arranger.findFoldedRows(in: root, at: [])
        let page = PageColumn(root: root)
        let pageHeight = height.rounded(.down)
        let fills = arranger.foldedRows.isEmpty && arranger.minimumHeight(of: page.entries) <= pageHeight
        let contentHeight = fills ? pageHeight : arranger.naturalHeight(of: page.entries)
        if !page.isWrapped {
            arranger.record(at: [], frame: Frame(x: 0, y: 0, width: arranger.pageWidth, height: contentHeight))
        }
        arranger.placeColumn(page.entries, x: 0, y: 0, width: arranger.pageWidth, height: contentHeight, fitted: fills)
        return Arrangement(
            width: arranger.pageWidth,
            height: contentHeight.rounded(),
            scrolls: !fills,
            frames: arranger.frames,
            containerFrames: arranger.containerFrames,
            foldedRows: arranger.foldedRows)
    }
}

private struct PageColumn {
    let entries: [Entry]
    let isWrapped: Bool

    init(root: InstrumentLayout.Node) {
        if case .column(let entries) = root.content {
            self.entries = entries.indices.map { Entry(node: entries[$0], path: [$0]) }
            isWrapped = false
        } else {
            entries = [Entry(node: root, path: [])]
            isWrapped = true
        }
    }
}

private struct Entry {
    let node: InstrumentLayout.Node
    let path: InstrumentLayout.Path
}

private struct Arranger {
    typealias Node = InstrumentLayout.Node
    typealias Frame = InstrumentLayout.Frame

    let widgets: [String: InstrumentWidget]
    let rowCounts: [String: Int]
    let subtitledRowCounts: [String: Int]
    let metrics: InstrumentLayout.Metrics
    let pageWidth: Double
    var frames: [String: Frame] = [:]
    var containerFrames: [InstrumentLayout.Path: Frame] = [:]
    var foldedRows: Set<InstrumentLayout.Path> = []

    init(widgets: [InstrumentWidget], rowCounts: [String: Int], subtitledRowCounts: [String: Int], metrics: InstrumentLayout.Metrics, pageWidth: Double) {
        self.widgets = Dictionary(widgets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.rowCounts = rowCounts
        self.subtitledRowCounts = subtitledRowCounts
        self.metrics = metrics
        self.pageWidth = pageWidth
    }

    mutating func findFoldedRows(in node: Node, at path: InstrumentLayout.Path) {
        if case .row(let entries) = node.content, pageWidth < node.foldBelow.map(Double.init) ?? foldWidth(of: entries) {
            foldedRows.insert(path)
        }
        for index in node.entries.indices {
            findFoldedRows(in: node.entries[index], at: path + [index])
        }
    }

    func minimumHeight(of entries: [Entry]) -> Double {
        entries.map { $0.node.share == nil ? naturalHeight(of: $0) : minimumHeight(of: $0) }.reduce(0, +) + gaps(entries.count)
    }

    func naturalHeight(of entries: [Entry]) -> Double {
        entries.map(naturalHeight).reduce(0, +) + gaps(entries.count)
    }

    mutating func record(at path: InstrumentLayout.Path, frame: Frame) {
        containerFrames[path] = rounded(frame)
    }

    mutating func placeColumn(_ entries: [Entry], x: Double, y: Double, width: Double, height: Double, fitted: Bool) {
        let heights = fitted ? filledHeights(of: entries, in: height) : naturalHeights(of: entries, in: height)
        var top = y
        for (entry, entryHeight) in zip(entries, heights) {
            place(entry, x: x, y: top, width: width, height: entryHeight, fitted: fitted && entry.node.share != nil)
            top += entryHeight + metrics.spacing
        }
    }

    private func foldWidth(of entries: [Node]) -> Double {
        Double(entries.count) * InstrumentLayout.foldWidthPerEntry
    }

    private func gaps(_ count: Int) -> Double {
        Double(max(count - 1, 0)) * metrics.spacing
    }

    private func naturalHeight(of entry: Entry) -> Double {
        switch entry.node.content {
        case .widget(let id):
            return naturalHeight(of: widgets[id]!, maxRows: entry.node.maxRows)
        case .row:
            let entries = children(of: entry)
            return foldedRows.contains(entry.path) ? naturalHeight(of: entries) : entries.map(naturalHeight).max()!
        case .column:
            return naturalHeight(of: children(of: entry))
        }
    }

    private func minimumHeight(of entry: Entry) -> Double {
        switch entry.node.content {
        case .widget(let id):
            return minimumHeight(of: widgets[id]!, maxRows: entry.node.maxRows)
        case .row:
            return children(of: entry).map(minimumHeight).max()!
        case .column:
            return minimumHeight(of: children(of: entry))
        }
    }

    private func children(of entry: Entry) -> [Entry] {
        entry.node.entries.indices.map { Entry(node: entry.node.entries[$0], path: entry.path + [$0]) }
    }

    private func filledHeights(of entries: [Entry], in height: Double) -> [Double] {
        var heights = entries.map { $0.node.share == nil ? naturalHeight(of: $0) : 0 }
        var open = entries.indices.filter { entries[$0].node.share != nil }
        var remaining = height - heights.reduce(0, +) - gaps(entries.count)
        while !open.isEmpty {
            let shares = Double(open.map { entries[$0].node.share! }.reduce(0, +))
            let starved = open.filter { minimumHeight(of: entries[$0]) > remaining * Double(entries[$0].node.share!) / shares }
            guard !starved.isEmpty else {
                for index in open {
                    heights[index] = remaining * Double(entries[index].node.share!) / shares
                }
                break
            }
            for index in starved {
                heights[index] = minimumHeight(of: entries[index])
                remaining -= heights[index]
            }
            open.removeAll { starved.contains($0) }
        }
        return heights
    }

    private func naturalHeights(of entries: [Entry], in height: Double) -> [Double] {
        var heights = entries.map(naturalHeight)
        let shared = entries.indices.filter { entries[$0].node.share != nil }
        let slack = height - heights.reduce(0, +) - gaps(entries.count)
        let shares = Double(shared.map { entries[$0].node.share! }.reduce(0, +))
        for index in shared where slack > 0 {
            heights[index] += slack * Double(entries[index].node.share!) / shares
        }
        return heights
    }

    private mutating func place(_ entry: Entry, x: Double, y: Double, width: Double, height: Double, fitted: Bool) {
        let frame = Frame(x: x, y: y, width: width, height: height)
        switch entry.node.content {
        case .widget(let id):
            frames[id] = rounded(frame)
        case .row:
            record(at: entry.path, frame: frame)
            if foldedRows.contains(entry.path) {
                placeFolded(children(of: entry), x: x, y: y, width: width)
            } else {
                placeRow(children(of: entry), x: x, y: y, width: width, height: height, fitted: fitted)
            }
        case .column:
            record(at: entry.path, frame: frame)
            placeColumn(children(of: entry), x: x, y: y, width: width, height: height, fitted: fitted)
        }
    }

    private mutating func placeFolded(_ entries: [Entry], x: Double, y: Double, width: Double) {
        var top = y
        for entry in entries {
            let entryHeight = naturalHeight(of: entry)
            place(entry, x: x, y: top, width: width, height: entryHeight, fitted: false)
            top += entryHeight + metrics.spacing
        }
    }

    private mutating func placeRow(_ entries: [Entry], x: Double, y: Double, width: Double, height: Double, fitted: Bool) {
        let shares = entries.map { Double($0.node.share ?? 1) }
        let available = width - gaps(entries.count)
        let total = shares.reduce(0, +)
        var left = x
        for (entry, share) in zip(entries, shares) {
            let entryWidth = available * share / total
            place(entry, x: left, y: y, width: entryWidth, height: height, fitted: fitted)
            left += entryWidth + metrics.spacing
        }
    }

    private func rounded(_ frame: Frame) -> Frame {
        let x = frame.x.rounded()
        let y = frame.y.rounded()
        return Frame(x: x, y: y, width: (frame.x + frame.width).rounded() - x, height: (frame.y + frame.height).rounded() - y)
    }

    private func naturalHeight(of widget: InstrumentWidget, maxRows: Int?) -> Double {
        chrome(of: widget) + naturalContentHeight(of: widget, maxRows: maxRows)
    }

    private func minimumHeight(of widget: InstrumentWidget, maxRows: Int?) -> Double {
        chrome(of: widget) + minimumContentHeight(of: widget, maxRows: maxRows)
    }

    private func chrome(of widget: InstrumentWidget) -> Double {
        let header = widget.hasHeader ? metrics.headerHeight + metrics.headerSpacing : 0
        return header + 2 * metrics.boxInset
    }

    private func naturalContentHeight(of widget: InstrumentWidget, maxRows: Int?) -> Double {
        let rows = min(rowCounts[widget.id] ?? 0, maxRows ?? InstrumentLayout.defaultRowCap)
        switch widget.kind {
        case .counter: return metrics.counterHeight
        case .list: return rows == 0 ? metrics.lineHeight : listHeight(of: widget, rows: rows)
        case .table: return rows == 0 ? metrics.lineHeight : tableHeight(rows: rows)
        case .console: return 250
        case .hex: return 16 * metrics.lineHeight
        case .graph, .histogram: return 180
        case .view(let cfg): return Double(cfg.height)
        }
    }

    private func listHeight(of widget: InstrumentWidget, rows: Int) -> Double {
        let subtitled = min(subtitledRowCounts[widget.id] ?? 0, rows)
        return Double(rows - subtitled) * metrics.rowHeight + Double(subtitled) * metrics.twoLineRowHeight
    }

    private func tableHeight(rows: Int) -> Double {
        metrics.tableHeaderHeight + Double(rows) * metrics.rowHeight
    }

    private func minimumContentHeight(of widget: InstrumentWidget, maxRows: Int?) -> Double {
        let rows = Double(min(4, maxRows ?? InstrumentLayout.defaultRowCap))
        switch widget.kind {
        case .list: return listHeight(of: widget, rows: Int(rows))
        case .table: return tableHeight(rows: Int(rows))
        case .console: return 120
        case .hex: return 6 * metrics.lineHeight
        case .view(let cfg): return Double(cfg.height)
        case .counter, .graph, .histogram: return naturalContentHeight(of: widget, maxRows: maxRows)
        }
    }
}
