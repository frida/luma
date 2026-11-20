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
    @State private var imageSource: ImageSource = .starter
    @State private var record: VirtualMachineRecord?
    @State private var machine: (any VirtualMachine)?
    @State private var presentation = VirtualMachinePresentation()
    @State private var failure: String?
    @State private var isBooting = false
    @State private var isMarkingReady = false
    @State private var isImporting = false
    @State private var awaitedImport: String?
    @State private var importingParameter: VirtualMachineParameter?
    @State private var isShowingCommandLine = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Boot Virtual Machine")
                    .font(.title3.weight(.semibold))

                Spacer()

                if machine?.display != nil {
                    VirtualMachinePageToggle(presentation: presentation)
                }
            }

            if let record {
                machineView(record)
            } else if isBooting {
                bootingView
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
        .frame(minWidth: 680, minHeight: 460, maxHeight: 720)
        .onAppear(perform: selectFirstAvailableTemplate)
        .task { await engine.virtualMachines.prewarm() }
        .task { await engine.fridaReleases.refresh() }
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
            List(engine.virtualMachines.templates, id: \.id, selection: templateSelection) { template in
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

                    if let starterImages = template.variant(for: effectiveParameters).starterImages {
                        imageSourcePicker(starterImages)
                    }

                    if let flavor = template.variant(for: effectiveParameters).agentFlavor {
                        agentSection(flavor)
                    }

                    Section("Parameters") {
                        ForEach(template.parameters.filter { !hiddenParameterIDs.contains($0.id) }) { parameter in
                            parameterField(parameter)
                        }
                    }

                    commandLineSection(template)
                }
                .formStyle(.grouped)
                .contentMargins(.top, 0)
                }
                .id(template.id)
            }
        }
        .frame(height: Self.setupHeight)
    }

    private var templateSelection: Binding<String?> {
        Binding(
            get: { selectedTemplateID },
            set: { newValue in
                selectedTemplateID = newValue
                adoptTemplateDefaults()
            }
        )
    }

    @ViewBuilder
    private func parameterField(_ parameter: VirtualMachineParameter) -> some View {
        switch parameter.kind {
        case .text:
            TextField(parameter.name, text: textBinding(parameter))

        case .number(_, let minimum, let maximum, let unit):
            LabeledContent(parameter.name) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("", value: numberBinding(parameter), format: .number)
                        .labelsHidden()
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
                HStack(alignment: .firstTextBaseline) {
                    if let path = parameters[parameter.id]?.text, !path.isEmpty {
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                    } else if let implicit = implicitValue(of: parameter) {
                        Text("Default: \(implicit)")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if parameters[parameter.id]?.text?.isEmpty == false {
                        Button {
                            parameters[parameter.id] = .text("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear")
                    }
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

        case .textList:
            textListRows(parameter)
        }
    }

    @ViewBuilder
    private func textListRows(_ parameter: VirtualMachineParameter) -> some View {
        LabeledContent(parameter.name) {
            Button {
                parameters[parameter.id] = .textList(textList(parameter) + [""])
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add Argument")
        }

        ForEach(textList(parameter).indices, id: \.self) { index in
            HStack {
                TextField("Argument", text: textListBinding(parameter, at: index))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))

                Button {
                    var list = textList(parameter)
                    list.remove(at: index)
                    parameters[parameter.id] = .textList(list)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
            }
        }
    }

    private func imageSourcePicker(_ images: StarterImages) -> some View {
        Picker(selection: $imageSource) {
            Text(images.distribution).tag(ImageSource.starter)
            Text("Your Own Files").tag(ImageSource.own)
        } label: {
            Text("System")
            if imageSource == .starter {
                Text(starterDescription(images))
            }
        }
    }

    private func starterDescription(_ images: StarterImages) -> String {
        switch engine.virtualMachines.starterImages.state(for: images) {
        case .ready:
            return "Downloaded"
        case .missing:
            return "Downloaded when you boot"
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
                await engine.virtualMachines.agents.loadInstalledVersion(for: flavor)
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
            guard let version = agents.installedVersion(for: flavor) else {
                return "Downloaded \(flavor.name)"
            }
            return "Downloaded \(flavor.name) · \(version.displayName)"
        case .downloading(let fraction):
            return downloadingLabel(fraction)
        case .missing:
            return "Downloaded when you boot"
        case .failed(let reason):
            return reason
        }
    }

    @ViewBuilder
    private func commandLineSection(_ template: VirtualMachineTemplate) -> some View {
        switch Result(catching: { try engine.virtualMachines.commandLine(for: template, parameters: previewParameters) }) {
        case .success(nil):
            EmptyView()
        case .success(let commandLine?):
            commandLineDisclosure(
                ScrollView(.horizontal) {
                    Text(commandLine.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(.bottom, 8)
                }
            )
        case .failure(let error):
            commandLineDisclosure(
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            )
        }
    }

    private func commandLineDisclosure(_ content: some View) -> some View {
        Section {
            DisclosureGroup("Command Line", isExpanded: $isShowingCommandLine) {
                content
            }
        }
    }

    private var previewParameters: [String: VirtualMachineParameterValue] {
        guard imageSource == .starter, let images = selectedStarterImages else { return parameters }
        let starterPaths = engine.virtualMachines.starterImages.destinations(for: images).mapValues {
            VirtualMachineParameterValue.text($0.path)
        }
        return parameters.merging(starterPaths) { _, starter in starter }
    }

    private enum ImageSource {
        case starter
        case own
    }

    private static let agentImport = "barebone-agent"
    private static let listRowInset: CGFloat = 10
    private static let formGroupInset: CGFloat = 20
    private static let setupHeight: CGFloat = 400

    private func machineView(_ record: VirtualMachineRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VirtualMachineView(engine: engine, record: record, presentation: presentation, logHeight: nil)
                .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)

            Text("Drive the machine to the state you want to come back to, then mark it ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var bootingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(bootingLabel)
                        .foregroundStyle(.secondary)
                }
                .environment(\.colorScheme, .dark)
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)

            Text("Drive the machine to the state you want to come back to, then mark it ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(height: Self.setupHeight)
    }

    private var bootingLabel: String {
        if imageSource == .starter, let images = selectedStarterImages,
            case .downloading(let fraction) = engine.virtualMachines.starterImages.state(for: images)
        {
            let progress = fraction.map { " \(Int($0 * 100))%" } ?? ""
            return "Downloading \(images.distribution)…\(progress)"
        }
        return "Booting \(machineName)…"
    }

    private var actions: some View {
        HStack {
            Spacer()

            Button(record == nil && !isBooting ? "Cancel" : "Later") { finish() }
                .disabled(isMarkingReady)

            if machine != nil || isBooting {
                Button {
                    markReady()
                } label: {
                    if isMarkingReady {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Marking Ready…")
                        }
                    } else {
                        Text("Mark Ready")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(machine == nil || isMarkingReady)
            } else {
                Button("Boot") { boot() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReadyToBoot)
            }
        }
    }

    private func markReady() {
        guard let machine else { return }
        isMarkingReady = true
        perform {
            defer { isMarkingReady = false }
            try await engine.virtualMachines.markReady(machine)
            finish()
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

        let starterImages = imageSource == .starter ? selectedStarterImages : nil

        isBooting = true
        perform {
            defer { isBooting = false }
            var bootParameters = parameters
            if let starterImages {
                for (parameter, path) in try await engine.virtualMachines.starterImages.download(starterImages) {
                    bootParameters[parameter] = .text(path.path)
                }
            }
            do {
                machine = try await engine.virtualMachines.create(
                    template: template,
                    name: machineName,
                    parameters: bootParameters,
                    agentPath: agentPath
                ) { record in
                    self.record = record
                    engine.setSidePanel(.virtualMachines)
                }
            } catch {
                record = nil
                throw error
            }
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
        imageSource = .starter
        parameters = selectedTemplate?.defaultParameterValues ?? [:]
        autoName = defaultMachineName()
        machineName = autoName
    }

    private func defaultMachineName() -> String {
        selectedTemplate?.name ?? ""
    }

    private func refreshDefaultName() {
        guard machineName == autoName else { return }
        autoName = defaultMachineName()
        machineName = autoName
    }

    private func availabilityText(for template: VirtualMachineTemplate) -> String {
        if let reason = engine.virtualMachines.availability(for: template).reason { return reason }
        return template.variants.map(\.architecture.displayName).joined(separator: " \u{00b7} ")
    }

    private var allowedImportTypes: [UTType] {
        guard case .filePath(let extensions)? = importingParameter?.kind, !extensions.isEmpty else { return [.data] }
        return extensions.compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    private var selectedTemplate: VirtualMachineTemplate? {
        engine.virtualMachines.templates.first { $0.id == selectedTemplateID }
    }

    private var effectiveParameters: [String: VirtualMachineParameterValue] {
        guard let selectedTemplate else { return parameters }
        return engine.virtualMachines.resolvedParameters(for: selectedTemplate, parameters: parameters)
    }

    private var hiddenParameterIDs: Set<String> {
        var hidden: Set<String> = [VirtualMachineTemplate.architectureParameterID]
        if imageSource == .starter, let images = selectedStarterImages {
            hidden.formUnion(images.parameterIDs)
        }
        return hidden
    }

    private var selectedStarterImages: StarterImages? {
        selectedTemplate?.variant(for: effectiveParameters).starterImages
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

    private func implicitValue(of parameter: VirtualMachineParameter) -> String? {
        guard let selectedTemplate else { return nil }
        return engine.virtualMachines.implicitValue(of: parameter, for: selectedTemplate, parameters: parameters)
    }

    private func toggleBinding(_ parameter: VirtualMachineParameter) -> Binding<Bool> {
        Binding(
            get: { parameters[parameter.id]?.toggle ?? false },
            set: { parameters[parameter.id] = .toggle($0) }
        )
    }

    private func textList(_ parameter: VirtualMachineParameter) -> [String] {
        parameters[parameter.id]?.textList ?? []
    }

    private func textListBinding(_ parameter: VirtualMachineParameter, at index: Int) -> Binding<String> {
        Binding(
            get: { textList(parameter).indices.contains(index) ? textList(parameter)[index] : "" },
            set: {
                var list = textList(parameter)
                list[index] = $0
                parameters[parameter.id] = .textList(list)
            }
        )
    }
}

#endif
