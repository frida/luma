import LumaCore
import SwiftUI
import SwiftyPharo

/// Evaluates Smalltalk against the embedded image and hands the result to the
/// inspector.
struct PharoPlaygroundView: View {
    @State private var source = "1 to: 20"
    @State private var result: PharoObject?
    @State private var failure: String?
    @State private var isReady = false

    private let runtime = PharoRuntime.shared

    var body: some View {
        VSplitView {
            editor
            outcome
        }
        .task { await start() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 60)

            HStack {
                Button("Evaluate") { Task { await evaluate() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isReady)

                if !isReady {
                    ProgressView().controlSize(.small)
                    Text("Starting the image…").foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var outcome: some View {
        if let failure {
            ContentUnavailableView(failure, systemImage: "exclamationmark.triangle")
        } else if let result {
            PharoInspectorView(runtime: runtime, root: result)
        } else {
            ContentUnavailableView("Nothing evaluated yet", systemImage: "text.and.command.macwindow")
        }
    }

    private func start() async {
        guard !isReady else { return }

        guard let image = Self.bundledImage else {
            failure = "No Pharo image in the app bundle"
            return
        }

        runtime.boot(image: image)
        do {
            try await runtime.runningState()
            isReady = true
        } catch {
            failure = "\(error)"
        }
    }

    private func evaluate() async {
        do {
            result = try await runtime.evaluate(source)
            failure = nil
        } catch {
            result = nil
            failure = "\(error)"
        }
    }

    private static var bundledImage: URL? {
        Bundle.main.urls(forResourcesWithExtension: "image", subdirectory: nil)?.first
    }
}
