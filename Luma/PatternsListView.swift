import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct PatternsListView: View {
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var creatingKind: PatternSource.Kind?
    @State private var newName = ""
    @State private var isImporting = false
    @State private var isShowingPackageSearch = false
    @State private var errorMessage: String?

    private var projectSources: [PatternSource] { engine.patterns.projectSources }
    private var packageSources: [PatternSource] { engine.patterns.packageSources }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if projectSources.isEmpty && packageSources.isEmpty {
                emptyState
            } else {
                toolbar
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .sheet(isPresented: $isShowingPackageSearch) {
            VStack(alignment: .leading) {
                Text("Add Pattern Package")
                    .font(.title2)
                    .bold()
                    .padding(.bottom, 8)
                PackageSearchView(engine: engine, selection: $selection, category: .pattern)
            }
            .padding()
        }
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

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Import…") { isImporting = true }
            newMenu
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.top)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            EmptyStateHeading(
                title: "Patterns",
                systemImage: "square.stack.3d.up",
                subtitle: "Describe structs to decode memory against, or add ready-made ones for PE, Mach-O and ELF."
            )

            HStack(spacing: 8) {
                Button {
                    startCreating(.pattern)
                } label: {
                    Label("New Pattern", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button("New Library") { startCreating(.library) }
                    .buttonStyle(.bordered)

                Button("Add Package…") { isShowingPackageSearch = true }
                    .buttonStyle(.bordered)

                Button("Import…") { isImporting = true }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            if !projectSources.isEmpty {
                Section("Project") {
                    rows(projectSources)
                }
            }
            if !packageSources.isEmpty {
                Section("Packages") {
                    rows(packageSources)
                }
            }
        }
        .listStyle(.inset)
    }

    private func rows(_ sources: [PatternSource]) -> some View {
        ForEach(sources) { source in
            Button {
                selection = .pattern(source.id)
            } label: {
                PatternListRow(source: source)
            }
            .buttonStyle(.plain)
        }
    }

    private var newMenu: some View {
        Menu {
            Button("New Pattern") { startCreating(.pattern) }
            Button("New Library") { startCreating(.library) }
        } label: {
            Text("New")
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
            Image(systemName: source.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.headline)
                Text(source.originDescription)
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
