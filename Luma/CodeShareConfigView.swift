import SwiftUI
import SwiftyMonaco

struct CodeShareConfigView: View {
    @Binding var config: CodeShareConfig
    @ObservedObject var workspace: Workspace

    @State private var draftSource: String = ""
    @State private var isDirty = false
    @State private var showSavedCheck = false

    @State private var errorMessage: String?

    @StateObject private var monacoIntrospector = MonacoIntrospector()

    var body: some View {
        VStack(spacing: 12) {
            header
            trustBanner
            formFields
            Divider()
            editor
        }
        .padding(.top, 4)
        .onAppear {
            draftSource = config.source
        }
        .onChange(of: draftSource) { _, newValue in
            isDirty = (newValue != config.source)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.headline)

                if let project = config.project {
                    Text("@\(project.owner)/\(project.slug)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Local snippet (not published)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                saveStatusIcon

                Button("Save") {
                    saveDraft()
                }
                .disabled(!isDirty)
            }

            if let project = config.project {
                Button {
                    Platform.openURL(project.url)
                } label: {
                    Image(systemName: "safari")
                }
                .help("Open on CodeShare")
            }
        }
    }

    private var trustBanner: some View {
        let current = config.currentSourceHash
        let reviewed = config.lastReviewedHash
        let synced = config.lastSyncedHash

        return Group {
            if reviewed == nil {
                Label(
                    "Not yet reviewed. Please audit this script before enabling.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .padding(6)
                .background(Color.yellow.opacity(0.15))
                .cornerRadius(6)
            } else if current != reviewed {
                HStack {
                    Label(
                        "Locally modified since last review.",
                        systemImage: "pencil.and.outline"
                    )
                    Spacer()
                    Button("Mark as reviewed") {
                        config.lastReviewedHash = current
                    }
                }
                .font(.caption)
                .padding(6)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            } else if let synced, synced != current {
                Label(
                    "Differs from last synced version on CodeShare.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .padding(6)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $config.name)

            TextField(
                "Description",
                text: $config.description,
                axis: .vertical
            )
            .lineLimit(2...4)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            CodeEditorView(
                text: $draftSource,
                profile: CodeShareEditorProfile.javascript,
                introspector: monacoIntrospector,
                workspace: workspace,
            )
        }
    }

    private var saveStatusIcon: some View {
        ZStack {
            if isDirty {
                Circle()
                    .frame(width: 6, height: 6)
            }
            if showSavedCheck {
                Image(systemName: "checkmark.circle.fill")
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(width: 14, height: 14)
    }

    private func saveDraft() {
        errorMessage = nil

        Task { @MainActor in
            let symbols = await monacoIntrospector.topLevelSymbols()

            config.source = draftSource
            config.exports = symbols.map(\.text)
            config.lastReviewedHash = config.currentSourceHash
            isDirty = false

            showSavedCheck = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation {
                showSavedCheck = false
            }
        }
    }
}
