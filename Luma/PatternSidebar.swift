import Frida
import LumaCore
import SwiftUI

struct PatternsSidebarRows: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var outlines: [String: [PatternTypeSummary]] = [:]
    @State private var expanded: Set<String> = []

    private var sources: [PatternSource] { engine.patterns.sources }

    var body: some View {
        SidebarPatternsRow(count: sources.count)
            .tag(SidebarItemID.patterns)
        ForEach(sources) { source in
            let types = outlines[source.id] ?? []
            let isExpanded = expanded.contains(source.id)
            SidebarPatternRow(
                source: source,
                engine: engine,
                selection: $selection,
                hasTypes: !types.isEmpty,
                isExpanded: isExpanded,
                onToggleExpansion: { toggle(source.id) }
            )
            .tag(SidebarItemID.pattern(source.id))
            if isExpanded {
                PatternTypeSidebarChildren(source: source, types: types, selection: $selection)
            }
        }
        .task(id: sources) {
            await outline()
        }
        .onChange(of: selection, initial: true) {
            if let selectedSource {
                expanded.insert(selectedSource)
            }
        }
    }

    private var selectedSource: String? {
        switch selection {
        case .pattern(let id), .patternType(let id, _):
            return id
        default:
            return nil
        }
    }

    private func toggle(_ sourceID: String) {
        if expanded.contains(sourceID) {
            expanded.remove(sourceID)
        } else {
            expanded.insert(sourceID)
        }
    }

    private func outline() async {
        for source in sources {
            guard let summary = try? await engine.patternDecoder.summary(of: source) else { continue }
            outlines[source.id] = summary.declaredTypes
        }
    }
}

private struct PatternTypeSidebarChildren: View {
    let source: PatternSource
    let types: [PatternTypeSummary]
    @Binding var selection: SidebarItemID?

    var body: some View {
        let highlights = types.sidebarHighlights(selectedID: selectedTypeName)
        ForEach(highlights) { type in
            SidebarFeatureRowLabel(
                icon: { Image(systemName: type.kind.symbolName).font(.system(size: 11)) },
                title: type.name,
                help: type.kind.title
            )
            .tag(SidebarItemID.patternType(source.id, type.name))
        }
        if types.count > highlights.count {
            SidebarBrowseAllRow(count: types.count) { dismiss in
                SidebarBrowserPopover(
                    placeholder: "Filter types",
                    emptyMessage: "No matching types",
                    items: types,
                    groupName: { $0.kind.title },
                    title: { $0.name },
                    help: { $0.kind.title },
                    isDimmed: { _ in false },
                    matches: { type, query in type.name.localizedCaseInsensitiveContains(query) },
                    onChoose: { type in
                        selection = .patternType(source.id, type.name)
                        dismiss()
                    }
                )
            }
        }
    }

    private var selectedTypeName: String? {
        if case .patternType(let id, let name) = selection, id == source.id { return name }
        return nil
    }
}

private struct SidebarPatternsRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .frame(width: 18, alignment: .center)
            Text("Patterns")
            Spacer()
            if count > 0 {
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.patterns")
    }
}

private struct SidebarPatternRow: View {
    let source: PatternSource
    let engine: Engine
    @Binding var selection: SidebarItemID?
    let hasTypes: Bool
    let isExpanded: Bool
    let onToggleExpansion: () -> Void

    @State private var isShowingRename = false
    @State private var newName = ""
    @State private var isShowingDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            SidebarDisclosure(isExpanded: isExpanded, canToggle: hasTypes, onToggle: onToggleExpansion)
            Image(systemName: source.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: sidebarChildIconWidth)
                .padding(.trailing, sidebarIconToLabelSpacing)
            Text(source.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.pattern.\(source.id)")
        .contextMenu {
            Button {
                newName = source.name
                isShowingRename = true
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Rename \(source.kind.title)", isPresented: $isShowingRename) {
            TextField("Name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(source.name)?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(source.id) from the pattern library.")
        }
        .alert("Pattern library error", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func rename() {
        do {
            let renamed = try engine.patterns.rename(source.id, to: newName)
            if selection == .pattern(source.id) {
                selection = .pattern(renamed.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try engine.patterns.delete(source.id)
            if selection == .pattern(source.id) {
                selection = .patterns
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

extension PatternSource.Kind {
    var title: String {
        switch self {
        case .pattern:
            return "Pattern"
        case .library:
            return "Library"
        }
    }

    var symbolName: String {
        switch self {
        case .pattern:
            return "doc.text"
        case .library:
            return "books.vertical"
        }
    }
}

extension PatternTypeKind {
    var title: String {
        switch self {
        case .struct:
            return "Struct"
        case .union:
            return "Union"
        case .enum:
            return "Enum"
        case .bitfield:
            return "Bitfield"
        case .alias:
            return "Alias"
        }
    }

    var symbolName: String {
        switch self {
        case .struct, .union:
            return "curlybraces"
        case .enum:
            return "list.number"
        case .bitfield:
            return "01.square"
        case .alias:
            return "equal"
        }
    }
}
