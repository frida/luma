import LumaCore
import SwiftUI

struct SwiftTypesView: View {
    let sessionID: UUID
    let module: LumaCore.ProcessModule
    let engine: Engine
    @Binding var selection: SidebarItemID?

    @State private var outline: SwiftTypesOutline?
    @State private var loadError: String?
    @State private var filterText = ""
    @State private var selectedTypeName: String?
    @FocusState private var filterFocused: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: isSwiftBridgeLoaded) {
                await loadOutline()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch outline {
            case .available(let types):
                typesTable(types)
            case .needsBridge:
                SwiftBridgeInstallPrompt(engine: engine)
            case .absent:
                EmptyStateHeading(
                    title: "No Swift Types",
                    systemImage: "swift",
                    subtitle: "\(module.name) carries no Swift metadata."
                )
                .frame(maxHeight: .infinity)
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func typesTable(_ types: [SwiftTypeSummary]) -> some View {
        let shown = matching(types)
        return VStack(spacing: 0) {
            Table(shown, selection: $selectedTypeName) {
                TableColumn("Name") { type in Text(type.displayName(inModule: module.name)) }
                TableColumn("Kind") { type in Text(type.kind.title).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80, max: 120)
            }
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { names in
                if let name = names.first, let type = types.first(where: { $0.name == name }) {
                    selection = .swiftType(sessionID, module.id, type)
                }
            }
            .detailPaneInset(.leading)
            .padding(.top, 8)

            Divider()
            DetailFilterBar(text: $filterText, isFocused: $filterFocused) {
                DetailFilterStatus(text: "\(shown.count) of \(types.count)")
            }
        }
    }

    private func matching(_ types: [SwiftTypeSummary]) -> [SwiftTypeSummary] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return types }
        return types.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var isSwiftBridgeLoaded: Bool {
        engine.node(forSessionID: sessionID)?.loadedPackageNames.contains(SwiftTypesOutline.bridgePackageName) ?? false
    }

    private func loadOutline() async {
        guard let node = engine.node(forSessionID: sessionID) else {
            loadError = "Process is detached."
            return
        }
        do {
            outline = try await node.outlineModule(name: module.name).swiftTypes
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct SwiftBridgeInstallPrompt: View {
    let engine: Engine

    @State private var isInstalling = false
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 16) {
            EmptyStateHeading(
                title: "Swift Types",
                systemImage: "swift",
                subtitle: "Browsing Swift types needs the \(SwiftTypesOutline.bridgePackageName) package."
            )
            Button {
                install()
            } label: {
                if isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Install \(SwiftTypesOutline.bridgePackageName)")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInstalling)
            if let installError {
                Text(installError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func install() {
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do {
                try await engine.installSwiftBridge()
                installError = nil
            } catch {
                installError = error.localizedDescription
            }
        }
    }
}
