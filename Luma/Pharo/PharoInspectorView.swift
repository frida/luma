import SwiftUI
import SwiftyPharo

/// Walks an object through the views it declares, opening each selection in a
/// column to its right so the path taken to reach a value stays on screen.
struct PharoInspectorView: View {
    let runtime: PharoRuntime
    let root: PharoObject

    @State private var path: [PharoObject] = []

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(path.enumerated()), id: \.element.handle) { depth, object in
                        if depth > 0 {
                            PharoDrillArrow()
                        }

                        PharoObjectColumn(runtime: runtime, object: object) { selected in
                            open(selected, from: depth)
                        }
                        .frame(width: 320)
                        .pharoPane()
                        .id(object.handle)
                    }
                }
            }
            .onChange(of: path.count) {
                withAnimation { scroller.scrollTo(path.last?.handle, anchor: .trailing) }
            }
            // SwiftUI hands a new root to the view it already has, so seeding
            // the path from an initializer would only ever run once.
            .onChange(of: root.handle, initial: true) { startOver(at: root) }
        }
    }

    private func open(_ object: PharoObject, from depth: Int) {
        path = path.prefix(depth + 1) + [object]
    }

    private func startOver(at object: PharoObject) {
        path = [object]
    }
}

/// One object's declared views, as a tab per view.
private struct PharoObjectColumn: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let onSelect: (PharoObject) -> Void

    @State private var declarations: [PharoViewDeclaration] = []
    @State private var shown: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if declarations.count > 1 {
                // More tabs than the card is wide should scroll rather than
                // squeeze every title down to an ellipsis.
                ScrollView(.horizontal) {
                    Picker("", selection: $shown) {
                        ForEach(declarations, id: \.methodSelector) { declaration in
                            Text(declaration.title).tag(Optional(declaration.methodSelector))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .scrollIndicators(.hidden)
                .padding(6)
            }

            Divider()
            content
        }
        .task { await loadDeclarations() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(object.printString)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("pharo.inspector.printString")
            Text(object.className)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            PharoFailureView(message: failure)
        } else if let shownDeclaration {
            body(of: shownDeclaration)
        } else {
            ContentUnavailableView("No views", systemImage: "square.dashed")
        }
    }

    @ViewBuilder
    private func body(of declaration: PharoViewDeclaration) -> some View {
        switch declaration.viewName {
        case "list", "columnedList", "tree":
            PharoItemsList(
                runtime: runtime,
                object: object,
                view: declaration.methodSelector,
                onSelect: onSelect)
        case "text":
            ScrollView {
                Text(declaration.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        default:
            ContentUnavailableView(
                "\(declaration.viewName) views are not rendered yet", systemImage: "square.dashed")
        }
    }

    private var shownDeclaration: PharoViewDeclaration? {
        declarations.first { $0.methodSelector == shown } ?? declarations.first
    }

    private func loadDeclarations() async {
        do {
            declarations = try await runtime.views(of: object)
            shown = declarations.first?.methodSelector
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Pages its rows in as they are needed, so a large collection costs only the
/// rows that have been looked at.
private struct PharoItemsList: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let view: String
    let onSelect: (PharoObject) -> Void

    @State private var rows: [String] = []
    @State private var total = 0
    @State private var failure: String?

    private let pageSize = 50

    var body: some View {
        List {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Button {
                    Task { await drill(into: index) }
                } label: {
                    Text(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if rows.count < total {
                Button("Show more (\(total - rows.count) left)") {
                    Task { await loadNextPage() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .listStyle(.plain)
        // Switching tabs hands the same list a different view to page through.
        .task(id: view) { await reload() }
    }

    private func reload() async {
        rows = []
        total = 0
        failure = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        do {
            let page = try await runtime.items(
                of: object, view: view, from: rows.count + 1, count: pageSize)
            total = page.total
            rows += page.items
        } catch {
            failure = error.localizedDescription
        }
    }

    private func drill(into index: Int) async {
        do {
            onSelect(try await runtime.drillInto(object, view: view, index: index + 1))
        } catch {
            failure = error.localizedDescription
        }
    }
}
