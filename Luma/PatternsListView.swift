import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct PatternsListView: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var creatingKind: PatternSource.Kind?
    @State private var newName = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var sources: [PatternSource] { engine.patterns.sources }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Patterns")
                    .font(.title2.bold())
                Spacer()
                Button {
                    isImporting = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                newMenu
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.top)

            if sources.isEmpty {
                ContentUnavailableView {
                    Label("No patterns yet", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Pattern files describe structs to decode memory against. Libraries hold definitions shared between them.")
                } actions: {
                    newMenu
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sources) { source in
                        Button {
                            selection = .pattern(source.id)
                        } label: {
                            PatternListRow(source: source)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .alert("New \(creatingKind?.title ?? "")", isPresented: isCreating) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .alert("Pattern library error", isPresented: errorBinding, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var newMenu: some View {
        Menu {
            Button("New Pattern") { startCreating(.pattern) }
            Button("New Library") { startCreating(.library) }
        } label: {
            Label("New", systemImage: "plus.circle.fill")
        }
        .fixedSize()
    }

    private func startCreating(_ kind: PatternSource.Kind) {
        newName = ""
        creatingKind = kind
    }

    private var isCreating: Binding<Bool> {
        Binding(
            get: { creatingKind != nil },
            set: { if !$0 { creatingKind = nil } }
        )
    }

    private func create() {
        guard let kind = creatingKind else { return }
        do {
            let created = try engine.patterns.create(named: newName, kind: kind)
            selection = .pattern(created.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            var imported: PatternSource?
            for url in try result.get() {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                imported = try engine.patterns.importFile(at: url)
            }
            if let imported {
                selection = .pattern(imported.id)
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

private struct PatternListRow: View {
    let source: PatternSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.headline)
                Text(source.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(source.kind.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
