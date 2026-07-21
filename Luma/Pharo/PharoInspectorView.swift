import SwiftUI
import SwiftyPharo

/// Walks an object through the views it declares, opening each selection in a
/// column to its right so the path taken to reach a value stays on screen.
struct PharoInspectorView: View {
    let runtime: PharoRuntime
    let root: PharoObject
    let onClose: () -> Void

    @State private var path: [PharoObject] = []
    @State private var shown: Int?

    var body: some View {
        ScrollViewReader { scroller in
            VStack(spacing: 0) {
                overview { handle in
                    withAnimation { scroller.scrollTo(handle, anchor: .leading) }
                }
                Divider()
                columns
            }
            .onChange(of: path.last?.handle) {
                withAnimation { scroller.scrollTo(path.last?.handle, anchor: .trailing) }
            }
            // SwiftUI hands a new root to the view it already has, so seeding
            // the path from an initializer would only ever run once.
            .onChange(of: root.handle, initial: true) { startOver(at: root) }
        }
    }

    /// The panes as blocks, the way Glamorous Toolkit previews them: no words,
    /// just where in the path each one sits.
    private func overview(_ scrollTo: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(path.enumerated()), id: \.element.handle) { depth, object in
                Button {
                    shown = depth
                    scrollTo(object.handle)
                } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(depth == shown ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25))
                        .frame(height: previewHeight)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help(object.printString)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private let previewHeight: CGFloat = 14

    private var columns: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(path.enumerated()), id: \.element.handle) { depth, object in
                    if depth > 0 {
                        PharoDrillArrow()
                    }

                    PharoObjectColumn(
                        runtime: runtime,
                        object: object,
                        onSelect: { open($0, from: depth) },
                        onClose: { close(from: depth) })
                    .frame(width: 320)
                    .pharoPane()
                    .id(object.handle)
                }
            }
        }
    }

    private func open(_ object: PharoObject, from depth: Int) {
        path = path.prefix(depth + 1) + [object]
        shown = path.count - 1
    }

    private func startOver(at object: PharoObject) {
        path = [object]
        shown = 0
    }

    private func close(from depth: Int) {
        guard depth > 0 else { return onClose() }
        path = Array(path.prefix(depth))
        shown = min(shown ?? 0, path.count - 1)
    }
}

/// One object's declared views, as a tab per view.
private struct PharoObjectColumn: View {
    let runtime: PharoRuntime
    let object: PharoObject
    let onSelect: (PharoObject) -> Void
    let onClose: () -> Void

    @State private var declared: Declared = .pending
    @State private var shown: String?

    /// Nothing declared and not asked yet are different things: rendering them
    /// alike flashes "No views" over every object on its way in.
    private enum Declared {
        case pending
        case ready([PharoViewDeclaration])
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .overlay(alignment: .topTrailing) { closeButton }

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(6)
        .accessibilityIdentifier("pharo.inspection.close")
    }

    @ViewBuilder
    private var content: some View {
        switch declared {
        case .pending:
            Color.clear
        case .failed(let message):
            PharoFailureView(message: message)
        case .ready:
            if let shownDeclaration {
                body(of: shownDeclaration)
            } else {
                ContentUnavailableView("No views", systemImage: "square.dashed")
            }
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

    private var declarations: [PharoViewDeclaration] {
        guard case .ready(let declarations) = declared else { return [] }
        return declarations
    }

    private func loadDeclarations() async {
        do {
            let loaded = try await runtime.views(of: object)
            declared = .ready(loaded)
            shown = loaded.first?.methodSelector
        } catch {
            declared = .failed(error.localizedDescription)
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

    @State private var rows: [[PharoCell]] = []
    @State private var total = 0
    @State private var selection: Int?
    @State private var failure: String?

    private let pageSize = 50

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                PharoRowView(cells: row).tag(index)
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
        .onChange(of: selection) { _, row in
            guard let row else { return }
            Task { await drill(into: row) }
        }
    }

    private func reload() async {
        rows = []
        total = 0
        selection = nil
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
