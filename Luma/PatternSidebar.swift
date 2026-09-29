import LumaCore
import SwiftUI

struct PatternsSidebarRows: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?

    private var sources: [PatternSource] { engine.patterns.sources }

    var body: some View {
        SidebarPatternsRow(count: sources.count)
            .tag(SidebarItemID.patterns)
        ForEach(sources) { source in
            SidebarPatternRow(source: source, engine: engine, selection: $selection)
                .tag(SidebarItemID.pattern(source.id))
        }
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

    @State private var isShowingRename = false
    @State private var newName = ""
    @State private var isShowingDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: source.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: sidebarChildIconWidth)
            Text(source.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, sidebarChildIndent)
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
