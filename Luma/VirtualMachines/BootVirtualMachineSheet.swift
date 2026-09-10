import Frida
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)

struct BootVirtualMachineSheet: View {
    let engine: Engine
    let deviceAdded: (Device) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: String?
    @State private var machineName: String = ""
    @State private var autoName: String = ""
    @State private var agentPath: URL?
    @State private var parameters: [String: VirtualMachineParameterValue] = [:]
    @State private var machine: (any VirtualMachine)?
    @State private var failure: String?
    @State private var isBooting = false
    @State private var isImporting = false
    @State private var awaitedImport: String?
    @State private var importingParameter: VirtualMachineParameter?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Boot Virtual Machine")
                .font(.title3.weight(.semibold))

            if let machine {
                bootedView(machine)
            } else {
                templateChooser
            }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            actions
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .onAppear(perform: selectFirstAvailableTemplate)
        .task { await engine.virtualMachines.agents.refreshReleases() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: allowedImportTypes) { result in
            if let awaitedImport, case .success(let url) = result {
                if awaitedImport == Self.agentImport {
                    agentPath = url
                } else {
                    parameters[awaitedImport] = .text(url.path)
                }
            }
            awaitedImport = nil
        }
    }

    private var templateChooser: some View {
        HStack(alignment: .top, spacing: 16) {
            List(engine.virtualMachines.templates, id: \.id, selection: $selectedTemplateID) { template in
                HStack(spacing: 8) {
                    if let icon = template.icon {
                        icon.swiftUIImage
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 24, height: 24)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name)
                        Text(availabilityText(for: template))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(template.id)
            }
            .contentMargins(.top, 0)
            .frame(width: 220)
            .onChange(of: selectedTemplateID) { _, _ in adoptTemplateDefaults() }
            .onChange(of: parameters) { _, _ in refreshDefaultName() }

            if let template = selectedTemplate {
                VStack(alignment: .leading, spacing: 0) {
                Text(template.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, Self.listRowInset)
                    .padding(.horizontal, Self.formGroupInset)

                Form {
                    TextField("Name", text: $machineName)

                    if let architecture = template.parameters.first(where: {
                        $0.id == VirtualMachineTemplate.architectureParameterID
                    }) {
                        parameterField(architecture)
                    }

                    if let starterImages = template.variant(for: parameters).starterImages {
                        starterSection(starterImages)
                    }

                    ForEach(template.parameters.filter { $0.id != VirtualMachineTemplate.architectureParameterID }) { parameter in
                        parameterField(parameter)
                    }

                    if let flavor = template.variant(for: parameters).agentFlavor {
                        agentSection(flavor)
                    }
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
                .contentMargins(.top, 0)

                Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func parameterField(_ parameter: VirtualMachineParameter) -> some View {
        switch parameter.kind {
        case .text:
            TextField(parameter.name, text: textBinding(parameter))

        case .number(_, let minimum, let maximum, let unit):
            LabeledContent(parameter.name) {
                HStack {
                    TextField("", value: numberBinding(parameter), format: .number)
                        .frame(width: 80)
                    if let unit {
                        Text(unit).foregroundStyle(.secondary)
                    }
                    Stepper("", value: numberBinding(parameter), in: minimum...maximum, step: 64)
                        .labelsHidden()
                }
            }

        case .filePath:
            LabeledContent(parameter.name) {
                HStack {
                    Text(parameters[parameter.id]?.text ?? "")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") {
                        awaitedImport = parameter.id
                        importingParameter = parameter
                        isImporting = true
                    }
                }
            }

        case .choice(let options, _):
            Picker(parameter.name, selection: textBinding(parameter)) {
                ForEach(options) { option in
                    Text(option.name).tag(option.id)
                }
            }

        case .toggle:
            Toggle(parameter.name, isOn: toggleBinding(parameter))
        }
    }

    @ViewBuilder
    private func starterSection(_ images: StarterImages) -> some View {
        LabeledContent("Starter files") {
            HStack {
                Text(starterDescription(images))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Download") {
                    perform {
                        let paths = try await engine.virtualMachines.starterImages.download(images)
                        for (parameter, path) in paths {
                            parameters[parameter] = .text(path.path)
                        }
                    }
                }
                .help("Download \(images.name) and fill these in")
                .disabled(engine.virtualMachines.starterImages.state(for: images).isDownloading)
            }
        }
    }

    private func starterDescription(_ images: StarterImages) -> String {
        switch engine.virtualMachines.starterImages.state(for: images) {
        case .ready, .missing:
            return images.name
        case .downloading(let fraction):
            return downloadingLabel(fraction)
        case .failed(let reason):
            return reason
        }
    }

    private func downloadingLabel(_ fraction: Double?) -> String {
        guard let fraction else { return "Downloading…" }
        return "Downloading… \(Int(fraction * 100))%"
    }

    @ViewBuilder
    private func agentSection(_ flavor: BareboneAgentFlavor) -> some View {
        Section("Barebone Agent") {
            VStack(alignment: .leading, spacing: 6) {
                Text(agentDescription(flavor))
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Choose…") {
                        awaitedImport = Self.agentImport
                        importingParameter = nil
                        isImporting = true
                    }

                    agentDownloadButton(flavor)
                }
            }
            .task(id: flavor) {
                await engine.virtualMachines.agents.loadFetchedVersion(for: flavor)
            }
        }
    }

    @ViewBuilder
    private func agentDownloadButton(_ flavor: BareboneAgentFlavor) -> some View {
        let agents = engine.virtualMachines.agents
        let state = agents.state(for: flavor)

        if agentPath != nil {
            EmptyView()
        } else if state != .ready {
            Button(agents.latestVersion(for: flavor).map { "Download \($0)" } ?? "Download") {
                perform { try await agents.downloadLatest(flavor) }
            }
            .disabled(state.isDownloading)
        } else if case .available(let version) = agents.update(for: flavor) {
            Button("Update to \(version)") {
                perform { try await agents.downloadLatest(flavor) }
            }
        }
    }

    private func agentDescription(_ flavor: BareboneAgentFlavor) -> String {
        if let agentPath {
            return agentPath.path
        }

        let agents = engine.virtualMachines.agents
        switch agents.state(for: flavor) {
        case .ready:
            guard let version = agents.fetchedVersion(for: flavor) else {
                return "Downloaded \(flavor.name)"
            }
            return "Downloaded \(flavor.name) · \(version)"
        case .downloading(let fraction):
            return downloadingLabel(fraction)
        case .missing:
            return "Not downloaded yet"
        case .failed(let reason):
            return reason
        }
    }

    private static let agentImport = "barebone-agent"
    private static let listRowInset: CGFloat = 10
    private static let formGroupInset: CGFloat = 20

    private func bootedView(_ machine: any VirtualMachine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let display = machine.display {
                VirtualMachineDisplayView(display: display)
                    .frame(maxWidth: .infinity, minHeight: 320)
            }

            Text("Drive the machine to the state you want to come back to, then mark it ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Spacer()

            Button(machine == nil ? "Cancel" : "Later") { finish() }

            if let machine {
                Button("Mark Ready") {
                    perform {
                        try await engine.virtualMachines.markReady(machine)
                        finish()
                    }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Boot") { boot() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBooting || !isReadyToBoot)
            }
        }
    }

    private func finish() {
        if let machine, let device = engine.virtualMachines.device(for: machine) {
            deviceAdded(device)
        }
        dismiss()
    }

    private func boot() {
        guard let template = selectedTemplate else { return }

        isBooting = true
        perform {
            defer { isBooting = false }
            machine = try await engine.virtualMachines.create(
                template: template,
                name: machineName,
                parameters: parameters,
                agentPath: agentPath
            )
            engine.setSidePanel(.virtualMachines)
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do {
                try await work()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func selectFirstAvailableTemplate() {
        guard selectedTemplateID == nil else { return }
        selectedTemplateID = engine.virtualMachines.templates.first {
            engine.virtualMachines.availability(for: $0).isAvailable
        }?.id
        adoptTemplateDefaults()
    }

    private func adoptTemplateDefaults() {
        agentPath = nil
        parameters = selectedTemplate?.defaultParameterValues ?? [:]
        autoName = defaultMachineName()
        machineName = autoName
    }

    private func defaultMachineName() -> String {
        guard let template = selectedTemplate else { return "" }
        return "\(template.name) \(template.variant(for: parameters).architecture.displayName)"
    }

    private func refreshDefaultName() {
        guard machineName == autoName else { return }
        autoName = defaultMachineName()
        machineName = autoName
    }

    private func availabilityText(for template: VirtualMachineTemplate) -> String {
        engine.virtualMachines.availability(for: template).reason ?? template.architecture.rawValue
    }

    private var allowedImportTypes: [UTType] {
        guard case .filePath(let extensions)? = importingParameter?.kind, !extensions.isEmpty else { return [.data] }
        return extensions.compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    private var selectedTemplate: VirtualMachineTemplate? {
        engine.virtualMachines.templates.first { $0.id == selectedTemplateID }
    }

    private var isReadyToBoot: Bool {
        guard let selectedTemplate, !machineName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return engine.virtualMachines.availability(for: selectedTemplate).isAvailable
    }

    private func textBinding(_ parameter: VirtualMachineParameter) -> Binding<String> {
        Binding(
            get: { parameters[parameter.id]?.text ?? "" },
            set: { parameters[parameter.id] = .text($0) }
        )
    }

    private func numberBinding(_ parameter: VirtualMachineParameter) -> Binding<Int> {
        Binding(
            get: { parameters[parameter.id]?.number ?? 0 },
            set: { parameters[parameter.id] = .number($0) }
        )
    }

    private func toggleBinding(_ parameter: VirtualMachineParameter) -> Binding<Bool> {
        Binding(
            get: { parameters[parameter.id]?.toggle ?? false },
            set: { parameters[parameter.id] = .toggle($0) }
        )
    }
}

#endif
