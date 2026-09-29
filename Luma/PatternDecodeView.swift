import LumaCore
import SwiftUI

struct PatternDecodeView: View {
    let data: Data
    let baseAddress: UInt64?
    let sessionID: UUID
    let engine: Engine

    @State private var summaries: [String: PatternSummary] = [:]
    @State private var describeProblem: String?
    @State private var placements: [PatternPlacement] = []
    @State private var results: [PatternPlacement.ID: PlacementResult] = [:]
    @State private var locations: [UUID: NodeLocation] = [:]
    @State private var caret = 0
    @State private var selectedNodeID: UUID?
    @State private var expanded: Set<UUID> = []

    private var target: LumaCore.ProcessNode.ProcessInfo? {
        engine.node(forSessionID: sessionID)?.processInfo
    }

    private var canDecode: Bool {
        baseAddress != nil && target != nil && !engine.patterns.sources.isEmpty
    }

    private var describeKey: DescribeKey? {
        target.map { DescribeKey(sources: engine.patterns.sources, arch: $0.arch, platform: $0.platform) }
    }

    private var decodeKey: DecodeKey {
        DecodeKey(placements: placements, data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    hexView
                    if !placements.isEmpty {
                        tree.frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    hexView
                    if !placements.isEmpty {
                        tree
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

    private var annotations: [HexAnnotation] {
        locations.values
            .filter(\.isLeaf)
            .map { HexAnnotation(id: $0.node.id, range: $0.range, color: $0.color) }
    }

    private var emphasis: HexAnnotation? {
        selectedNodeID.flatMap { locations[$0] }.map { HexAnnotation(id: $0.node.id, range: $0.range, color: $0.color) }
    }

    private var tree: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(placements) { placement in
                PlacementRows(
                    placement: placement,
                    result: results[placement.id],
                    address: (baseAddress ?? 0) &+ UInt64(placement.offset),
                    locations: locations,
                    expanded: $expanded,
                    selection: $selectedNodeID,
                    remove: { placements.removeAll { $0.id == placement.id } }
                )
            }
        }
        .font(.system(.caption, design: .monospaced))
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
        for source in engine.patterns.sources where summaries[source.id] == nil {
            do {
                let summary = try await engine.patternDecoder.summary(of: source, arch: target.arch, platform: target.platform)
                summaries[source.id] = summary
            } catch {
                describeProblem = "\(source.name): \(error.localizedDescription)"
            }
        }
    }

    private func decodePlacements() async {
        guard let baseAddress, let target else { return }
        var results: [PatternPlacement.ID: PlacementResult] = [:]
        for placement in placements {
            guard let source = engine.patterns.source(withID: placement.sourceID) else { continue }
            let slice = data.suffix(from: data.startIndex + min(placement.offset, data.count))
            do {
                let value = try await engine.patternDecoder.decode(
                    source, typeName: placement.typeName, data: slice, address: baseAddress &+ UInt64(placement.offset),
                    arch: target.arch, platform: target.platform)
                results[placement.id] = .decoded(value)
            } catch {
                results[placement.id] = .failed(error.localizedDescription)
            }
        }
        guard !Task.isCancelled else { return }
        self.results = results
        locations = locate(results, base: baseAddress)
    }

    private func locate(_ results: [PatternPlacement.ID: PlacementResult], base: UInt64) -> [UUID: NodeLocation] {
        var located: [UUID: NodeLocation] = [:]
        for placement in placements {
            guard case .decoded(let root) = results[placement.id] else { continue }
            for (index, field) in root.children.enumerated() where !field.hidden {
                locate(field, ancestors: [placement.id], color: PatternPalette.color(for: field, index: index), base: base, into: &located)
            }
        }
        return located
    }

    private func locate(_ node: DecodedPattern, ancestors: [UUID], color: Color, base: UInt64, into located: inout [UUID: NodeLocation]) {
        let children = node.sealed ? [] : node.children.filter { !$0.hidden }
        let ownColor = node.color.flatMap(PatternPalette.color(hex:)) ?? color
        if let size = node.size, size > 0, node.address >= base {
            let start = Int(node.address - base)
            let isLeaf = !children.contains { ($0.size ?? 0) > 0 }
            located[node.id] = NodeLocation(node: node, range: start..<start + size, ancestors: ancestors, color: ownColor, isLeaf: isLeaf)
        }
        for child in children {
            locate(child, ancestors: ancestors + [node.id], color: ownColor, base: base, into: &located)
        }
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
                            place(PatternPlacement(sourceID: source.id, typeName: rootType, title: source.name, offset: 0))
                        }
                    }
                    ForEach(summary.decodableTypes) { type in
                        Button(type.name) {
                            place(PatternPlacement(sourceID: source.id, typeName: type.name, title: type.name, offset: caret))
                        }
                    }
                }
            }
        }
    }
}

struct PatternPlacement: Identifiable, Hashable {
    let id = UUID()
    let sourceID: String
    let typeName: String
    let title: String
    let offset: Int
}

private enum PlacementResult {
    case decoded(DecodedPattern)
    case failed(String)
}

private struct NodeLocation {
    let node: DecodedPattern
    let range: Range<Int>
    let ancestors: [UUID]
    let color: Color
    let isLeaf: Bool
}

private struct DescribeKey: Equatable {
    let sources: [PatternSource]
    let arch: String
    let platform: String
}

private struct DecodeKey: Equatable {
    let placements: [PatternPlacement]
    let data: Data
}

private struct PlacementRows: View {
    let placement: PatternPlacement
    let result: PlacementResult?
    let address: UInt64
    let locations: [UUID: NodeLocation]
    @Binding var expanded: Set<UUID>
    @Binding var selection: UUID?
    let remove: () -> Void

    private var isExpanded: Bool { expanded.contains(placement.id) }

    var body: some View {
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: isExpanded, isVisible: true) { toggle() }
            Text(placement.title)
                .fontWeight(.semibold)
            Text(String(format: "@ 0x%llx", address))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(action: remove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        switch result {
        case .decoded(let root):
            if isExpanded {
                ForEach(root.children.filter { !$0.hidden }) { child in
                    PatternNodeRows(node: child, depth: 1, locations: locations, expanded: $expanded, selection: $selection)
                }
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .padding(.leading, 14)
        case nil:
            EmptyView()
        }
    }

    private func toggle() {
        if isExpanded {
            expanded.remove(placement.id)
        } else {
            expanded.insert(placement.id)
        }
    }
}

private struct PatternNodeRows: View {
    let node: DecodedPattern
    let depth: Int
    let locations: [UUID: NodeLocation]
    @Binding var expanded: Set<UUID>
    @Binding var selection: UUID?

    private var children: [DecodedPattern] {
        node.sealed ? [] : node.children.filter { !$0.hidden }
    }

    private var isExpanded: Bool { expanded.contains(node.id) }

    var body: some View {
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: isExpanded, isVisible: !children.isEmpty) { toggle() }
            if let color = locations[node.id]?.color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(node.displayName ?? node.name)
                .fontWeight(.semibold)
            Text(node.typeName)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(node.summary)
                .foregroundStyle(node.truncated ? .red : .primary)
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 1)
        .background(selection == node.id ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { selection = node.id }
        .help(node.comment ?? String(format: "0x%llx", node.address))
        if isExpanded {
            ForEach(children) { child in
                PatternNodeRows(node: child, depth: depth + 1, locations: locations, expanded: $expanded, selection: $selection)
            }
        }
    }

    private func toggle() {
        if isExpanded {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
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

    static func color(for node: DecodedPattern, index: Int) -> Color {
        node.color.flatMap(color(hex:)) ?? colors[index % colors.count]
    }

    static func color(hex: String) -> Color? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }
}
