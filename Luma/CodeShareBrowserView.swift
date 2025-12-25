import CryptoKit
import SwiftUI
import SwiftyMonaco

struct CodeShareBrowserView: View {
    let session: ProcessSession
    @ObservedObject var workspace: Workspace
    let onInstrumentAdded: ((InstrumentInstance) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @StateObject private var service = CodeShareService.shared

    @State private var mode: CodeShareService.Mode = .popular
    @State private var searchQuery: String = ""
    @State private var projects: [CodeShareService.ProjectSummary] = []
    @State private var selectedProject: CodeShareService.ProjectSummary?
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var addInstrumentHandler: (() -> Void)?
    @State private var isAddingInstrument: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("CodeShare")
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Add Instrument") {
                    addInstrumentHandler?()
                }
                .disabled(addInstrumentHandler == nil || isAddingInstrument)
            }
        }
        .onAppear {
            Task {
                await loadPopular()
            }
        }
        .onChange(of: searchQuery) { _, newValue in
            Task {
                await performSearchDebounced(query: newValue)
            }
        }
        .onChange(of: selectedProject) { _, _ in
            addInstrumentHandler = nil
            isAddingInstrument = false
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Mode",
                selection: Binding<Int>(
                    get: {
                        switch mode {
                        case .popular:
                            return 0
                        case .search:
                            return 1
                        }
                    },
                    set: { idx in
                        switch idx {
                        case 0:
                            mode = .popular
                            projects = []
                            selectedProject = nil
                            Task { await loadPopular() }
                        default:
                            mode = .search(query: searchQuery)
                            projects = []
                            selectedProject = nil
                            Task { await performSearch() }
                        }
                    }
                )
            ) {
                Text("Popular").tag(0)
                Text("Search").tag(1)
            }
            .pickerStyle(.segmented)

            if case .search = mode {
                HStack {
                    TextField("Search CodeShare", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLoading)

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ZStack {
                List(selection: $selectedProject) {
                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)

                            Text("@\(project.owner)/\(project.slug)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                Text("\(project.likes)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .tag(project)
                    }
                }
                .listStyle(.sidebar)

                if case .popular = mode, isLoading && projects.isEmpty {
                    ProgressView()
                }
            }
        }
        .padding()
        .frame(minWidth: 260, idealWidth: 300)
    }

    @ViewBuilder
    private var detailView: some View {
        if let project = selectedProject {
            CodeShareProjectDetailView(
                project: project,
                workspace: workspace,
                session: session,
                registerAddAction: { handler in
                    addInstrumentHandler = handler
                },
                isAddingInstrument: $isAddingInstrument,
                onInstrumentAdded: { instance in
                    onInstrumentAdded?(instance)
                    dismiss()
                }
            )
        } else {
            Text("Select a snippet to preview and add it as an instrument.")
                .foregroundStyle(.secondary)
        }
    }

    private func loadPopular() async {
        isLoading = true
        loadError = nil
        do {
            let items = try await service.fetchPopular()
            projects = items
            if selectedProject == nil {
                selectedProject = projects.first
            }
        } catch {
            loadError = String(describing: error)
            projects = []
            selectedProject = nil
        }
        isLoading = false
    }

    private func performSearch() async {
        guard case .search = mode else { return }
        isLoading = true
        loadError = nil
        do {
            let items = try await service.searchProjects(query: searchQuery)
            projects = items
            if selectedProject == nil {
                selectedProject = projects.first
            }
        } catch {
            loadError = String(describing: error)
            projects = []
            selectedProject = nil
        }
        isLoading = false
    }

    private func performSearchDebounced(query: String) async {
        guard case .search = mode else { return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if query == searchQuery {
            await performSearch()
        }
    }
}

struct CodeShareProjectDetailView: View {
    let project: CodeShareService.ProjectSummary
    @ObservedObject var workspace: Workspace
    let session: ProcessSession
    let registerAddAction: (((() -> Void)?) -> Void)
    @Binding var isAddingInstrument: Bool
    let onInstrumentAdded: (InstrumentInstance) -> Void

    @State private var details: CodeShareService.ProjectDetails?
    @State private var source: String = ""
    @State private var isLoadingDetails = false
    @State private var loadError: String?
    @StateObject private var monacoIntrospector = MonacoIntrospector()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
            }

            if let details {
                VStack(alignment: .leading, spacing: 8) {
                    Text(details.description)
                        .font(.subheadline)

                    Text("Frida \(details.fridaVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("Source")
                        .font(.headline)

                    CodeEditorView(
                        text: $source,
                        profile: CodeShareEditorProfile.javascript,
                        introspector: monacoIntrospector
                    )
                }
            } else if isLoadingDetails {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a snippet to load details.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: project.id) {
            await loadDetails()
        }
        .onDisappear {
            registerAddAction(nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.title3.weight(.semibold))

            Text("@\(project.owner)/\(project.slug)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                Text("\(project.likes) likes")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func loadDetails() async {
        isLoadingDetails = true
        loadError = nil
        details = nil
        registerAddAction(nil)

        let currentID = project.id

        defer {
            if project.id == currentID {
                isLoadingDetails = false
            }
        }

        do {
            let d = try await CodeShareService.shared.fetchProjectDetails(
                owner: project.owner,
                slug: project.slug
            )

            guard project.id == currentID else { return }

            details = d
            source = d.source

            registerAddAction {
                Task { @MainActor in
                    guard !isAddingInstrument else { return }
                    isAddingInstrument = true
                    defer { isAddingInstrument = false }
                    await addInstrument(details: d)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard project.id == currentID else { return }
            loadError = String(describing: error)
            details = nil
            source = ""
        }
    }

    private func addInstrument(details: CodeShareService.ProjectDetails) async {
        let symbols = await monacoIntrospector.topLevelSymbols()

        let projectRef = CodeShareProjectRef(
            id: details.id,
            owner: details.owner,
            slug: details.slug
        )

        let finalSource = source

        let hash: String = {
            let data = Data(finalSource.utf8)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }()

        let cfg = CodeShareConfig(
            name: details.name,
            description: details.description,
            source: finalSource,
            exports: symbols.map(\.text),
            project: projectRef,
            lastSyncedHash: hash,
            lastReviewedHash: hash,
            fridaVersion: details.fridaVersion,
            allowRemoteUpdates: false
        )

        guard let configData = try? JSONEncoder().encode(cfg) else {
            return
        }

        let sourceIdentifier = "@\(details.owner)/\(details.slug)"

        let template = InstrumentTemplate(
            id: "codeshare:\(sourceIdentifier)",
            kind: .codeShare,
            sourceIdentifier: sourceIdentifier,
            displayName: cfg.name,
            icon: .system("cloud"),
            makeInitialConfigJSON: {
                configData
            },
            makeConfigEditor: { jsonBinding, _ in
                let cfgBinding = Binding<CodeShareConfig>(
                    get: {
                        (try? JSONDecoder().decode(
                            CodeShareConfig.self,
                            from: jsonBinding.wrappedValue
                        )) ?? cfg
                    },
                    set: { newValue in
                        if let data = try? JSONEncoder().encode(newValue) {
                            jsonBinding.wrappedValue = data
                        }
                    }
                )

                return AnyView(
                    CodeShareConfigView(
                        config: cfgBinding,
                        workspace: workspace
                    )
                )
            },
            makeAddressContextMenuItems: { context, workspace, selection in
                return []
            },
            renderEvent: { event, workspace, selection in
                if let v = event.payload as? JSInspectValue {
                    return AnyView(
                        JSInspectValueView(
                            value: v,
                            sessionID: event.process.sessionRecord.id,
                            workspace: workspace,
                            selection: selection
                        ))
                }
                return AnyView(Text(String(describing: event.payload)))
            },
            makeEventContextMenuItems: { _, _, _ in [] },
            summarizeEvent: { event in
                String(describing: event.payload)
            }
        )

        let newInstrument = await workspace.addInstrument(
            template: template,
            initialConfigJSON: configData,
            for: session
        )

        onInstrumentAdded(newInstrument)
    }
}
