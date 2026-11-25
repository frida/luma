import Foundation

extension InstrumentLayout {
    public enum Side: Sendable, CaseIterable {
        case leading
        case trailing
        case above
        case below

        var axis: Axis {
            switch self {
            case .leading, .trailing: return .horizontal
            case .above, .below: return .vertical
            }
        }

        var isAfter: Bool {
            self == .trailing || self == .below
        }
    }

    public enum Direction: Sendable, CaseIterable {
        case up
        case down
        case left
        case right

        var side: Side {
            switch self {
            case .up: return .above
            case .down: return .below
            case .left: return .leading
            case .right: return .trailing
            }
        }
    }

    public func placing(_ widget: String, _ side: Side, of target: Path) throws(Problem) -> InstrumentLayout {
        guard let from = path(of: widget) else {
            var tree = root
            tree.insert(.widget(widget), side, of: target)
            return try Self.finished(tree)
        }
        guard from != target else {
            throw Problem(path: [], text: "\"\(widget)\" cannot be placed beside itself")
        }
        return try relocating(from, side, of: target)
    }

    public func wrapping(_ entries: ClosedRange<Int>, in container: Path, as axis: Axis) throws(Problem) -> InstrumentLayout {
        guard entries.count >= 2 else {
            throw Problem(path: Self.steps(to: container, in: root), text: "wrapping takes at least two entries")
        }
        var tree = root
        let parentAxis = tree[container].axis
        let wrapped = tree[container].entries[entries].map { $0.moved(from: parentAxis, to: axis) }
        tree[container].entries.replaceSubrange(entries, with: [Node(axis.content(wrapped))])
        return try Self.finished(tree)
    }

    public func unwrapping(_ container: Path) throws(Problem) -> InstrumentLayout {
        guard let index = container.last else {
            throw Problem(path: [], text: "the page's root cannot be unwrapped")
        }
        var tree = root
        let parent = Array(container.dropLast())
        let node = tree[container]
        guard node.axis != nil else {
            throw Problem(path: Self.steps(to: container, in: root), text: "is not a row or a column")
        }
        let parentAxis = tree[parent].axis
        let entries = node.entries.map { $0.moved(from: node.axis, to: parentAxis) }
        tree[parent].entries.replaceSubrange(index...index, with: entries)
        return try Self.finished(tree)
    }

    public func moving(_ node: Path, _ direction: Direction) throws(Problem) -> InstrumentLayout {
        guard let index = node.last else {
            throw Problem(path: [], text: "the page's root cannot be moved")
        }
        let side = direction.side
        let parent = Array(node.dropLast())
        if root[parent].axis == side.axis {
            let neighbor = index + (side.isAfter ? 1 : -1)
            if root[parent].entries.indices.contains(neighbor) {
                var tree = root
                tree[parent].entries.swapAt(index, neighbor)
                return try Self.finished(tree)
            }
        }
        var child = parent
        while !child.isEmpty {
            let enclosing = Array(child.dropLast())
            if root[enclosing].axis == side.axis {
                return try relocating(node, side, of: child)
            }
            child = enclosing
        }
        throw Problem(path: Self.steps(to: node, in: root), text: "cannot move \(direction)")
    }

    public func removing(_ widget: String) -> InstrumentLayout? {
        guard let path = path(of: widget) else { return self }
        var tree = root
        tree[path] = .vacated
        return tree.canonical(asRoot: true).map(InstrumentLayout.init)
    }

    public func renaming(_ widget: String, to id: String) -> InstrumentLayout {
        guard let path = path(of: widget) else { return self }
        var tree = root
        tree[path].content = .widget(id)
        return InstrumentLayout(root: tree)
    }

    public func setting(_ key: SizeKey, to value: Int?, at path: Path, widgets: [InstrumentWidget]) throws(Problem) -> InstrumentLayout {
        var tree = root
        let node = tree[path]
        if let value {
            let kind = node.widgetID.flatMap { id in widgets.first { $0.id == id }?.kind }
            if let text = Self.sizeProblem(key, value, on: node, kind: kind, keys: .camelCase) {
                throw Problem(path: Self.steps(to: path, in: root) + [.key(KeyNames(.camelCase).name(of: key))], text: text)
            }
        }
        switch key {
        case .share: tree[path].share = value
        case .maxRows: tree[path].maxRows = value
        case .foldBelow: tree[path].foldBelow = value
        }
        return try Self.finished(tree)
    }

    public func savable(for widgets: [InstrumentWidget]) -> InstrumentLayout? {
        self == .stack(of: widgets) ? nil : self
    }

    private func relocating(_ from: Path, _ side: Side, of target: Path) throws(Problem) -> InstrumentLayout {
        var tree = root
        let origin = tree[Array(from.dropLast())].axis
        let node = tree[from].moved(from: origin, to: side.axis)
        tree[from] = .vacated
        tree.insert(node, side, of: target)
        return try Self.finished(tree)
    }

    private static func finished(_ tree: Node) throws(Problem) -> InstrumentLayout {
        let root = tree.canonical(asRoot: true)!
        if let problem = root.structureProblem(depth: 1) {
            throw problem
        }
        return InstrumentLayout(root: root)
    }
}

extension InstrumentLayout.Axis {
    func content(_ entries: [InstrumentLayout.Node]) -> InstrumentLayout.Node.Content {
        switch self {
        case .horizontal: return .row(entries)
        case .vertical: return .column(entries)
        }
    }
}

extension InstrumentLayout.KeyNames {
    func name(of key: InstrumentLayout.SizeKey) -> String {
        switch key {
        case .share: return share
        case .maxRows: return maxRows
        case .foldBelow: return foldBelow
        }
    }
}

extension InstrumentLayout.Node {
    static let vacated = InstrumentLayout.Node(.column([]))

    mutating func insert(_ node: InstrumentLayout.Node, _ side: InstrumentLayout.Side, of target: InstrumentLayout.Path) {
        guard let index = target.last else {
            if axis == side.axis {
                entries.insert(node, at: side.isAfter ? entries.count : 0)
            } else {
                self = InstrumentLayout.Node(side.axis.content(side.isAfter ? [self, node] : [node, self]))
            }
            return
        }
        let parent = Array(target.dropLast())
        if self[parent].axis == side.axis {
            self[parent].entries.insert(node, at: index + (side.isAfter ? 1 : 0))
            return
        }
        var wrapped = self[target]
        let share = wrapped.share
        wrapped.share = nil
        self[target] = InstrumentLayout.Node(side.axis.content(side.isAfter ? [wrapped, node] : [node, wrapped]), share: share)
    }

    func moved(from origin: InstrumentLayout.Axis?, to destination: InstrumentLayout.Axis?) -> InstrumentLayout.Node {
        var node = self
        if origin != destination {
            node.share = nil
        }
        return node
    }

    func canonical(asRoot: Bool) -> InstrumentLayout.Node? {
        guard axis != nil else { return self }
        var node = self
        node.entries = entries.compactMap { $0.canonical(asRoot: false) }.map { entry in
            var entry = entry
            if axis == .horizontal {
                entry.dropDefaultRowShare()
            }
            return entry
        }
        if node.entries.isEmpty {
            return nil
        }
        guard node.entries.count == 1, !asRoot else { return node }
        var only = node.entries[0]
        only.share = share
        return only
    }

    func structureProblem(depth: Int) -> InstrumentWidget.Problem? {
        guard let axis else { return nil }
        if depth > InstrumentLayout.maxDepth {
            return InstrumentWidget.Problem(path: [], text: InstrumentLayout.depthText(depth))
        }
        let limit = axis == .horizontal ? InstrumentLayout.maxRowEntries : InstrumentLayout.maxColumnEntries
        if entries.count > limit {
            return InstrumentWidget.Problem(path: [.key(containerKey!)], text: InstrumentLayout.entriesText(entries.count, in: axis))
        }
        for index in entries.indices {
            if let problem = entries[index].structureProblem(depth: depth + 1) {
                return InstrumentWidget.Problem(path: [.key(containerKey!), .index(index)] + problem.path, text: problem.text)
            }
        }
        return nil
    }
}
