import LumaCore
import SwiftUI

struct PatternDecodeView: View {
    let data: Data
    let baseAddress: UInt64?
    let sessionID: UUID
    let engine: Engine
    @Binding var placements: [PatternPlacement]
    var sizing: PatternDecodeSizing = .capped
    var onTruncated: (() -> Void)? = nil

    @State private var summaries: [String: PatternSummary] = [:]
    @State private var describeProblem: String?
    @State private var results: [PatternPlacement.ID: PlacementResult] = [:]
    @State private var locations: [UUID: PatternLocation] = [:]
    @State private var annotations: [HexAnnotation] = []
    @State private var caret = 0
    @State private var selectedNodeID: UUID?
    @State private var expanded: Set<UUID> = []
    @State private var visualizations: [UUID: NodeVisualization] = [:]
    @State private var openVisualizer: UUID?
    @State private var callOutcome: CallOutcome?
    @FocusState private var isTreeFocused: Bool

    private var target: LumaCore.ProcessNode.ProcessInfo? {
        engine.node(forSessionID: sessionID)?.processInfo
    }

    private var canDecode: Bool {
        baseAddress != nil && target != nil && !engine.patterns.sources.isEmpty
    }

    private var describeKey: DescribeKey? {
        target.map { DescribeKey(sources: engine.patterns.sources, platform: $0.platform, arch: $0.arch) }
    }

    private var decodeKey: DecodeKey {
        DecodeKey(placements: placements, data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    hexPane
                    if !placements.isEmpty {
                        treePane.frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    hexPane
                    if !placements.isEmpty {
                        treePane
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let describeProblem {
                Text(describeProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task(id: describeKey) {
            await describeSources()
        }
        .task(id: decodeKey) {
            await decodePlacements()
        }
    }

    private var caretLabel: String {
        String(format: "0x%llx", (baseAddress ?? 0) &+ UInt64(caret))
    }

    private var hexPane: some View {
        ScrollViewReader { proxy in
            DecodePane(sizing: sizing) {
                hexView
                    .padding(.top, TreeMetrics.inset)
            }
            .onChange(of: caret) { _, caret in
                proxy.scrollTo(caret / HexLayout.bytesPerRow)
            }
            .onChange(of: emphasis?.range.lowerBound) { _, start in
                if let start {
                    proxy.scrollTo(start / HexLayout.bytesPerRow)
                }
            }
        }
    }

    private var hexView: some View {
        HexView(
            data: data,
            baseAddress: baseAddress ?? 0,
            annotations: annotations,
            emphasis: emphasis,
            onCaretMove: { index in
                caret = index
                selectNode(at: index)
            }
        ) {
            if canDecode {
                Menu("Decode at \(caretLabel) as…") {
                    PlacementItems(sources: engine.patterns.sources, summaries: summaries, caret: caret, place: place)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var emphasis: HexAnnotation? {
        selectedNodeID.flatMap { locations[$0] }.map(\.annotation)
    }

    private var treePane: some View {
        ScrollViewReader { proxy in
            DecodePane(sizing: sizing) {
                tree
            }
            .onChange(of: selectedNodeID) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isTreeFocused)
        .overlay {
            if isTreeFocused {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return]) { press in
            navigate(press.key)
        }
    }

    private var tree: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(visibleRows) { row in
                treeRow(row)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(TreeMetrics.inset)
    }

    @ViewBuilder
    private func treeRow(_ row: TreeRow) -> some View {
        switch row.kind {
        case .placement(let placement):
            PlacementRow(
                id: placement.id,
                title: title(of: placement),
                address: (baseAddress ?? 0) &+ UInt64(placement.offset),
                failure: failure(of: placement),
                isExpanded: expanded.contains(row.id),
                highlight: highlight(of: row.id),
                actions: actions(for: row.id),
                remove: { placements.removeAll { $0.id == placement.id } }
            )
            .equatable()
        case .node(let node):
            NodeRow(
                node: node,
                depth: row.depth,
                isExpandable: row.isExpandable,
                isExpanded: expanded.contains(row.id),
                highlight: highlight(of: row.id),
                color: locations[node.id]?.color,
                visualization: visualizations[node.id],
                isVisualizerOpen: openVisualizer == node.id,
                callOutcome: callOutcome?.rowID == node.id ? callOutcome : nil,
                actions: actions(for: row.id)
            )
            .equatable()
        }
    }

    private func failure(of placement: PatternPlacement) -> String? {
        guard case .failed(let message) = results[placement.id] else { return nil }
        return message
    }

    private func highlight(of id: UUID) -> RowHighlight {
        guard selectedNodeID == id else { return .none }
        return isTreeFocused ? .focused : .unfocused
    }

    private func actions(for id: UUID) -> RowActions {
        RowActions(
            select: {
                selectedNodeID = id
                isTreeFocused = true
            },
            toggle: {
                if expanded.contains(id) {
                    expanded.remove(id)
                } else {
                    expanded.insert(id)
                }
            },
            press: { press(id) },
            showVisualizer: { shown in
                if shown {
                    selectedNodeID = id
                    openVisualizer = id
                } else if openVisualizer == id {
                    openVisualizer = nil
                }
            },
            dismissCallOutcome: {
                if callOutcome?.rowID == id {
                    callOutcome = nil
                }
            }
        )
    }

    private func navigate(_ key: KeyEquivalent) -> KeyPress.Result {
        let rows = visibleRows
        guard let current = rows.firstIndex(where: { $0.id == selectedNodeID }) else {
            selectedNodeID = rows.first?.id
            return rows.isEmpty ? .ignored : .handled
        }
        let row = rows[current]
        let isExpanded = expanded.contains(row.id)
        switch key {
        case .upArrow:
            selectedNodeID = rows[max(current - 1, 0)].id
        case .downArrow:
            selectedNodeID = rows[min(current + 1, rows.count - 1)].id
        case .leftArrow:
            if row.isExpandable && isExpanded {
                expanded.remove(row.id)
            } else if let parent = row.parent {
                selectedNodeID = parent
            }
        case .rightArrow:
            if row.isExpandable && !isExpanded {
                expanded.insert(row.id)
            } else if row.isExpandable {
                selectedNodeID = rows[current + 1].id
            }
        default:
            activate(row.id)
        }
        return .handled
    }

    private var visibleRows: [TreeRow] {
        var rows: [TreeRow] = []
        for placement in placements {
            guard case .decoded(let root) = results[placement.id] else {
                rows.append(TreeRow(id: placement.id, parent: nil, depth: 0, isExpandable: false, kind: .placement(placement)))
                continue
            }
            let children = root.visibleChildren
            rows.append(TreeRow(id: placement.id, parent: nil, depth: 0, isExpandable: !children.isEmpty, kind: .placement(placement)))
            if expanded.contains(placement.id) {
                appendRows(for: children, parent: placement.id, depth: 1, to: &rows)
            }
        }
        return rows
    }

    private func appendRows(for nodes: [DecodedPattern], parent: UUID, depth: Int, to rows: inout [TreeRow]) {
        for node in nodes {
            let children = node.visibleChildren
            rows.append(TreeRow(id: node.id, parent: parent, depth: depth, isExpandable: !children.isEmpty, kind: .node(node)))
            if expanded.contains(node.id) {
                appendRows(for: children, parent: node.id, depth: depth + 1, to: &rows)
            }
        }
    }

    private func activate(_ id: UUID) {
        guard let visualization = visualizations[id] else { return }
        if case .ready(let ready) = visualization.outcome, visualization.presentation == .inline, ready.isInline {
            press(id)
        } else {
            openVisualizer = openVisualizer == id ? nil : id
        }
    }

    private func press(_ id: UUID) {
        guard let visualization = visualizations[id], case .ready(.button(let function, _)) = visualization.outcome,
            let baseAddress, let target, let source = engine.patterns.source(withID: visualization.placement.sourceID)
        else { return }
        let placement = visualization.placement
        Task {
            do {
                let output = try await engine.patternDecoder.callFunction(
                    function, on: visualization.nodeID, of: source, typeName: placement.typeName, data: bytes(at: placement),
                    address: baseAddress &+ UInt64(placement.offset), platform: target.platform, arch: target.arch)
                callOutcome = CallOutcome(rowID: id, text: output.isEmpty ? "No output." : output, isFailure: false)
            } catch {
                callOutcome = CallOutcome(rowID: id, text: error.localizedDescription, isFailure: true)
            }
        }
    }

    private func title(of placement: PatternPlacement) -> String {
        if summaries[placement.sourceID]?.rootType == placement.typeName,
            let source = engine.patterns.source(withID: placement.sourceID)
        {
            return source.name
        }
        return placement.typeName
    }

    private func place(_ placement: PatternPlacement) {
        placements.append(placement)
        expanded.insert(placement.id)
    }

    private func selectNode(at index: Int) {
        let hits = locations.values.filter { $0.range.contains(index) }
        guard let innermost = hits.min(by: { ($0.range.count, -$0.ancestors.count) < ($1.range.count, -$1.ancestors.count) }) else {
            return
        }
        selectedNodeID = innermost.node.id
        expanded.formUnion(innermost.ancestors)
    }

    private func describeSources() async {
        guard let target else { return }
        var described: [String: PatternSummary] = [:]
        for source in engine.patterns.sources {
            do {
                described[source.id] = try await engine.patternDecoder.summary(of: source, platform: target.platform, arch: target.arch)
            } catch {
                describeProblem = "\(source.name): \(error.localizedDescription)"
            }
        }
        guard !Task.isCancelled else { return }
        summaries = described
    }

    private func decodePlacements() async {
        guard let baseAddress, let target else { return }
        var results: [PatternPlacement.ID: PlacementResult] = [:]
        for placement in placements {
            guard let source = engine.patterns.source(withID: placement.sourceID) else { continue }
            do {
                let value = try await engine.patternDecoder.decode(
                    source, typeName: placement.typeName, data: bytes(at: placement), address: baseAddress &+ UInt64(placement.offset),
                    platform: target.platform, arch: target.arch)
                results[placement.id] = .decoded(value)
            } catch {
                results[placement.id] = .failed(error.localizedDescription)
            }
        }
        guard !Task.isCancelled else { return }
        let remap = PatternNodeRemap(from: Self.roots(of: self.results), to: Self.roots(of: results), placements: Set(results.keys))
        self.results = results
        expanded = Set(expanded.compactMap(remap.callAsFunction))
        selectedNodeID = selectedNodeID.flatMap(remap.callAsFunction)
        openVisualizer = openVisualizer.flatMap(remap.callAsFunction)
        callOutcome = nil
        locations = locate(results, base: baseAddress)
        annotations = locations.values.filter(\.isLeaf).map(\.annotation)
        visualizations = visualize(results)
        if results.values.contains(where: \.isTruncated) {
            onTruncated?()
        }
    }

    private func bytes(at placement: PatternPlacement) -> Data {
        data.suffix(from: data.startIndex + min(placement.offset, data.count))
    }

    private static func roots(of results: [PatternPlacement.ID: PlacementResult]) -> [UUID: DecodedPattern] {
        results.compactMapValues { result in
            guard case .decoded(let root) = result else { return nil }
            return root
        }
    }

    private func visualize(_ results: [PatternPlacement.ID: PlacementResult]) -> [UUID: NodeVisualization] {
        var visualized: [UUID: NodeVisualization] = [:]
        for placement in placements {
            guard case .decoded(let root) = results[placement.id] else { continue }
            visualize(root, root: root, placement: placement, into: &visualized)
        }
        return visualized
    }

    private func visualize(
        _ node: DecodedPattern, root: DecodedPattern, placement: PatternPlacement, into visualized: inout [UUID: NodeVisualization]
    ) {
        if let visualizer = node.visualizer {
            let outcome: NodeVisualization.Outcome
            do {
                outcome = .ready(try PatternVisualization(visualizer, of: node, in: root))
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            visualized[node.id] = NodeVisualization(
                placement: placement, nodeID: node.nodeID, presentation: visualizer.presentation, outcome: outcome)
        }
        for child in node.children {
            visualize(child, root: root, placement: placement, into: &visualized)
        }
    }

    private func locate(_ results: [PatternPlacement.ID: PlacementResult], base: UInt64) -> [UUID: PatternLocation] {
        var located: [UUID: PatternLocation] = [:]
        for placement in placements {
            if case .decoded(let root) = results[placement.id] {
                PatternLocation.locateFields(of: root, under: placement.id, base: base, into: &located)
            }
        }
        return located
    }
}

private struct PlacementItems: View {
    let sources: [PatternSource]
    let summaries: [String: PatternSummary]
    let caret: Int
    let place: (PatternPlacement) -> Void

    var body: some View {
        ForEach(sources) { source in
            if let summary = summaries[source.id] {
                Section(source.name) {
                    if let rootType = summary.rootType {
                        Button("Run file") {
                            place(PatternPlacement(sourceID: source.id, typeName: rootType, offset: 0))
                        }
                    }
                    ForEach(summary.decodableTypes) { type in
                        Button(type.name) {
                            place(PatternPlacement(sourceID: source.id, typeName: type.name, offset: caret))
                        }
                    }
                }
            }
        }
    }
}

private struct TreeRow: Identifiable {
    let id: UUID
    let parent: UUID?
    let depth: Int
    let isExpandable: Bool
    let kind: Kind

    enum Kind {
        case placement(PatternPlacement)
        case node(DecodedPattern)
    }
}

private struct NodeVisualization {
    let placement: PatternPlacement
    let nodeID: UInt
    let presentation: DecodedVisualizer.Presentation
    let outcome: Outcome

    enum Outcome {
        case ready(PatternVisualization)
        case failed(String)
    }
}

private struct CallOutcome: Equatable {
    let rowID: UUID
    let text: String
    let isFailure: Bool
}

enum PatternDecodeSizing {
    case capped
    case fill
}

private struct DecodePane<Content: View>: View {
    let sizing: PatternDecodeSizing
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        switch sizing {
        case .capped:
            scrollView
                .frame(height: min(contentHeight, TreeMetrics.cappedPaneHeight))
        case .fill:
            scrollView
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var scrollView: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
        }
    }
}

private enum TreeMetrics {
    static let inset: CGFloat = 4
    static let cappedPaneHeight: CGFloat = 400
    static let rowHeight = HexMetrics.regular.rowHeight
}

private enum RowHighlight {
    case none
    case unfocused
    case focused
}

private struct RowActions {
    let select: () -> Void
    let toggle: () -> Void
    let press: () -> Void
    let showVisualizer: (Bool) -> Void
    let dismissCallOutcome: () -> Void
}

private enum PlacementResult {
    case decoded(DecodedPattern)
    case failed(String)

    var isTruncated: Bool {
        guard case .decoded(let root) = self else { return false }
        return root.truncated
    }
}

private struct DescribeKey: Equatable {
    let sources: [PatternSource]
    let platform: String
    let arch: String
}

private struct DecodeKey: Equatable {
    let placements: [PatternPlacement]
    let data: Data
}

private struct PlacementRow: View, Equatable {
    let id: UUID
    let title: String
    let address: UInt64
    let failure: String?
    let isExpanded: Bool
    let highlight: RowHighlight
    let actions: RowActions
    let remove: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.address == rhs.address && lhs.failure == rhs.failure
            && lhs.isExpanded == rhs.isExpanded && lhs.highlight == rhs.highlight
    }

    var body: some View {
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: isExpanded, isVisible: failure == nil, toggle: actions.toggle)
            Text(title)
                .fontWeight(.semibold)
            Text(String(format: "@ 0x%llx", address))
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(failure)
            }
            Spacer(minLength: 12)
            Button(action: remove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .modifier(RowStyle(highlight: highlight, select: actions.select))
    }
}

private struct NodeRow: View, Equatable {
    let node: DecodedPattern
    let depth: Int
    let isExpandable: Bool
    let isExpanded: Bool
    let highlight: RowHighlight
    let color: Color?
    let visualization: NodeVisualization?
    let isVisualizerOpen: Bool
    let callOutcome: CallOutcome?
    let actions: RowActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node.id == rhs.node.id && lhs.depth == rhs.depth && lhs.isExpandable == rhs.isExpandable
            && lhs.isExpanded == rhs.isExpanded && lhs.highlight == rhs.highlight && lhs.color == rhs.color
            && lhs.isVisualizerOpen == rhs.isVisualizerOpen && lhs.callOutcome == rhs.callOutcome
    }

    var body: some View {
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: isExpanded, isVisible: isExpandable, toggle: actions.toggle)
            if let color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(node.displayName ?? node.name)
                .fontWeight(.semibold)
            Text(node.typeName)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value
        }
        .padding(.leading, CGFloat(depth) * 14)
        .modifier(RowStyle(highlight: highlight, select: actions.select))
        .help(node.comment ?? String(format: "0x%llx", node.address))
    }

    @ViewBuilder
    private var value: some View {
        if let visualization {
            if case .ready(let ready) = visualization.outcome, visualization.presentation == .inline, ready.isInline {
                PatternInlineVisualizationView(visualization: ready, press: actions.press)
                    .popover(isPresented: callOutcomeShown, arrowEdge: .bottom) {
                        if let callOutcome {
                            Text(callOutcome.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(callOutcome.isFailure ? .red : .primary)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                    }
            } else {
                summary
                Button {
                    actions.showVisualizer(!isVisualizerOpen)
                } label: {
                    Image(systemName: symbolName(of: visualization))
                }
                .buttonStyle(.borderless)
                .help("Visualize")
                .popover(isPresented: visualizerShown, arrowEdge: .bottom) {
                    switch visualization.outcome {
                    case .ready(let ready):
                        PatternVisualizationView(visualization: ready)
                    case .failed(let message):
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding(10)
                    }
                }
            }
        } else {
            summary
        }
    }

    private var summary: some View {
        Text(node.summary)
            .foregroundStyle(node.truncated ? AnyShapeStyle(.red) : AnyShapeStyle(.foreground))
            .lineLimit(1)
    }

    private func symbolName(of visualization: NodeVisualization) -> String {
        guard case .ready(let ready) = visualization.outcome else { return "exclamationmark.triangle" }
        return ready.symbolName
    }

    private var visualizerShown: Binding<Bool> {
        Binding(get: { isVisualizerOpen }, set: actions.showVisualizer)
    }

    private var callOutcomeShown: Binding<Bool> {
        Binding(get: { callOutcome != nil }, set: { if !$0 { actions.dismissCallOutcome() } })
    }
}

private struct RowStyle: ViewModifier {
    let highlight: RowHighlight
    let select: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(height: TreeMetrics.rowHeight)
            .padding(.trailing, 2)
            .foregroundStyle(highlight == .focused ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(background, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
    }

    private var background: Color {
        switch highlight {
        case .none:
            .clear
        case .unfocused:
            Color.secondary.opacity(0.25)
        case .focused:
            .accentColor
        }
    }
}

private struct DisclosureChevron: View {
    let isExpanded: Bool
    let isVisible: Bool
    let toggle: () -> Void

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 10)
            .opacity(isVisible ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
    }
}

enum PatternPalette {
    private static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red]

    static func color(for tint: PatternTint) -> Color {
        switch tint {
        case .palette(let index):
            return colors[index % colors.count]
        case .rgb(let red, let green, let blue):
            return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }
    }
}

extension PatternLocation {
    var color: Color {
        PatternPalette.color(for: tint)
    }

    var annotation: HexAnnotation {
        HexAnnotation(id: node.id, range: range, color: color)
    }
}
