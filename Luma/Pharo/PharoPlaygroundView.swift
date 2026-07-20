import LumaCore
import SwiftUI
import SwiftyPharo

/// A scratch page of Smalltalk snippets, opening what they produce in the pane
/// beside it. Nothing here is kept; the notebook is where work is saved.
struct PharoPlaygroundView: View {
    @State private var snippets: [Snippet] = [Snippet(source: "1 to: 20")]
    @State private var inspection: PharoInspection?
    @State private var inspected: UUID?
    @State private var centers: [UUID: CGFloat] = [:]
    @State private var failure: String?
    @State private var isReady = false

    private let runtime = PharoRuntime.shared

    private struct Snippet: Identifiable {
        let id = UUID()
        var source: String
    }

    var body: some View {
        HStack(spacing: 0) {
            page
                .pharoPane()

            if let inspection {
                PharoInspectionPane(inspection: inspection, pointsFrom: inspected.flatMap { centers[$0] }) {
                    self.inspection = nil
                }
                .frame(minWidth: 320)
            }
        }
        .coordinateSpace(name: pharoPageSpace)
        .padding(8)
        .background(.pharoGutter)
        .task { await start() }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($snippets) { $snippet in
                    PharoSnippetView(
                        source: $snippet.source,
                        evaluate: { Task { await evaluate(snippet) } },
                        inspect: nil,
                        remove: snippets.count > 1 ? { remove(snippet) } : nil
                    )
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(pharoPageSpace)).midY
                    } action: { center in
                        centers[snippet.id] = center
                    }
                }

                addSnippetButton

                if let failure {
                    PharoFailureView(message: failure)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var addSnippetButton: some View {
        Button {
            snippets.append(Snippet(source: ""))
        } label: {
            Label("Add Snippet", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!isReady)
        .accessibilityIdentifier("pharo.playground.addSnippet")
    }

    private func start() async {
        guard !isReady else { return }

        do {
            try await runtime.startBundledImage()
            isReady = true
        } catch {
            failure = error.localizedDescription
        }
    }

    private func evaluate(_ snippet: Snippet) async {
        inspected = snippet.id
        do {
            inspection = .live(try await runtime.evaluate(snippet.source))
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }
}
