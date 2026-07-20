import LumaCore
import SwiftUI
import SwiftyPharo

/// Evaluates Smalltalk against the embedded image, opening what comes back in
/// the pane beside it.
struct PharoPlaygroundView: View {
    @State private var source = "1 to: 20"
    @State private var inspection: PharoInspection?
    @State private var failure: String?
    @State private var isReady = false

    private let runtime = PharoRuntime.shared

    var body: some View {
        HStack(spacing: 0) {
            editor

            if let inspection {
                PharoInspectionPane(inspection: inspection) { self.inspection = nil }
                    .frame(minWidth: 320)
            }
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

            if let failure {
                PharoFailureView(message: failure)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func evaluate() async {
        do {
            inspection = .live(try await runtime.evaluate(source))
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
