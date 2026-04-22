import Frida
import SwiftUI
import LumaCore

struct TargetPickerView: View {
    enum Mode: String {
        case spawn
        case attach
    }

    enum SpawnSubmode: String {
        case application
        case program
    }

    @StateObject private var store: DeviceListModel
    private let deviceManager: DeviceManager

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompactWidth: Bool { false }
    #endif

    let reason: String?
    let onSpawn: (Device, SpawnConfig) -> Void
    let onAttach: (Device, ProcessDetails) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pickerState: TargetPickerState?

    @State private var selectedDeviceID: Device.ID?

    @State private var remoteConfigs: [LumaCore.RemoteDeviceConfig] = []

    @State private var mode: Mode = .attach
    @State private var spawnSubmode: SpawnSubmode = .application

    @State private var loadingApplications = false
    @State private var applications: [ApplicationDetails] = []
    @State private var applicationError: String?
    @State private var applicationSearchText: String = ""
    @State private var selectedApplicationIdentifier: String?
    @State private var appArgumentsText: String = ""
    @State private var appEnvEntries: [EnvEntry] = []
    @State private var appWorkingDirectory: String = ""
    @State private var appStdio: Stdio = .pipe
    @State private var appAutoResume: Bool = true
    @State private var appArgumentsExpanded: Bool = false
    @State private var appEnvExpanded: Bool = false
    @State private var appWorkingDirExpanded: Bool = false
    @State private var appExecutionExpanded: Bool = false

    @State private var programPath: String = ""
    @State private var programArgumentsText: String = ""
    @State private var programEnvEntries: [EnvEntry] = []
    @State private var programWorkingDirectory: String = ""
    @State private var programStdio: Stdio = .pipe
    @State private var programAutoResume: Bool = true

    @State private var processes: [ProcessDetails] = []
    @State private var loadingProcesses = false
    @State private var processError: String?
    @State private var processSearchText: String = ""
    @FocusState private var focusedField: FocusedField?
    @State private var selectedProcessPID: UInt?

    @State private var showingAddRemoteSheet = false
    @State private var remoteAddress = ""
    @State private var remoteCertificate = ""
    @State private var remoteOrigin = ""
    @State private var remoteToken = ""
    @State private var remoteKeepalive = ""
    @State private var showingAdvancedRemoteOptions = false
    @State private var addRemoteError: String?

    enum FocusedField: Hashable {
        case processSearch
        case processList
    }

    init(
        deviceManager: DeviceManager,
        reason: String? = nil,
        onSpawn: @escaping (Device, SpawnConfig) -> Void,
        onAttach: @escaping (Device, ProcessDetails) -> Void
    ) {
        self.deviceManager = deviceManager
        self.reason = reason
        self.onSpawn = onSpawn
        self.onAttach = onAttach
        self._store = StateObject(wrappedValue: DeviceListModel(manager: deviceManager))
    }

    private var selectedDevice: Device? {
        guard let id = selectedDeviceID else { return nil }
        return store.devices.first { $0.id == id }
    }

    private var canSpawn: Bool {
        guard selectedDevice != nil else { return false }
        switch spawnSubmode {
        case .application:
            return selectedApplicationIdentifier != nil
        case .program:
            return !programPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if mode == .spawn {
                Button {
                    triggerSpawn()
                } label: {
                    Label("Spawn & Attach", systemImage: "play.circle")
                }
                .disabled(!canSpawn)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reason {
                LumaBanner(style: .info) {
                    Label {
                        Text(reason)
                            .font(.callout)
                    } icon: {
                        Image(systemName: "info.circle")
                    }

                    Spacer()
                }
            }

            NavigationSplitView {
                deviceListPane()
                    .navigationTitle("New Session")
                    .navigationSplitViewColumnWidth(min: 200, ideal: 250)
                    .toolbar {
                        if isCompactWidth {
                            sharedToolbar
                        }
                    }
            } detail: {
                VStack(alignment: .leading, spacing: 0) {
                    modeSelector()

                    Divider()

                    if let device = selectedDevice {
                        switch mode {
                        case .spawn:
                            spawnDetailPane(for: device)
                        case .attach:
                            processDetailPane(for: device)
                        }
                    } else {
                        ZStack {
                            Color.clear
                            ContentUnavailableView(
                                "Select a Device",
                                systemImage: "ipad.and.iphone",
                                description: Text("Choose a device on the left to start a new session.")
                            )
                        }
                    }
                }
                .navigationTitle("New Session")
                .toolbar { sharedToolbar }
            }
            .frame(minWidth: isCompactWidth ? 0 : 904, minHeight: isCompactWidth ? 0 : 400)
            .sheet(isPresented: $showingAddRemoteSheet) {
                addRemoteSheet()
            }
            .task {
                if pickerState == nil {
                    pickerState = TargetPickerState()
                }

                if let lastID = pickerState?.lastSelectedDeviceID,
                    store.devices.contains(where: { $0.id == lastID })
                {
                    selectedDeviceID = lastID
                } else if !isCompactWidth {
                    if let local = store.devices.first(where: { $0.kind == .local }) {
                        selectedDeviceID = local.id
                    } else {
                        selectedDeviceID = store.devices.first?.id
                    }
                }

                if let state = pickerState {
                    if let rawMode = state.lastModeRaw,
                        let savedMode = Mode(rawValue: rawMode)
                    {
                        mode = savedMode
                    } else {
                        mode = .attach
                    }

                    if let rawSub = state.lastSpawnSubmodeRaw,
                        let savedSub = SpawnSubmode(rawValue: rawSub)
                    {
                        spawnSubmode = savedSub
                    }

                    if let appID = state.lastSpawnApplicationID {
                        selectedApplicationIdentifier = appID
                    }

                    if let progPath = state.lastSpawnProgramPath {
                        programPath = progPath
                    }
                }
            }
            .onChange(of: store.devices) { _, newDevices in
                if let current = selectedDeviceID,
                    newDevices.contains(where: { $0.id == current })
                {
                    return
                }

                if let lastID = pickerState?.lastSelectedDeviceID,
                    newDevices.contains(where: { $0.id == lastID })
                {
                    selectedDeviceID = lastID
                    return
                }

                if !isCompactWidth {
                    if let local = newDevices.first(where: { $0.kind == .local }) {
                        selectedDeviceID = local.id
                    } else {
                        selectedDeviceID = newDevices.first?.id
                    }
                }
            }
            .onChange(of: selectedDeviceID) { _, newID in
                if let newID {
                    pickerState?.lastSelectedDeviceID = newID
                } else {
                    pickerState?.lastSelectedDeviceID = nil
                }
            }
            .onChange(of: mode) { _, newValue in
                pickerState?.lastModeRaw = newValue.rawValue
            }
            .onChange(of: spawnSubmode) { _, newValue in
                pickerState?.lastSpawnSubmodeRaw = newValue.rawValue
            }
            .onChange(of: selectedApplicationIdentifier) { _, newValue in
                pickerState?.lastSpawnApplicationID = newValue
            }
            .onChange(of: programPath) { _, newValue in
                pickerState?.lastSpawnProgramPath = newValue
            }
        }
    }

    @ViewBuilder
    private func modeSelector() -> some View {
        HStack {
            Picker("Mode", selection: $mode) {
                Text("Spawn").tag(Mode.spawn)
                Text("Attach").tag(Mode.attach)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            Spacer()

            Text(
                mode == .spawn
                    ? "Spawn a new app or program under Luma."
                    : "Attach to an already-running process on this device."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func spawnDetailPane(for device: Device) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            spawnHeader()
            Divider()

            switch spawnSubmode {
            case .application:
                applicationSpawnPane(for: device)
            case .program:
                programSpawnPane(for: device)
            }
        }
        .task(id: device.id) {
            await loadApplications(for: device)
        }
    }

    @ViewBuilder
    private func spawnHeader() -> some View {
        HStack {
            Spacer()

            Picker("Launch", selection: $spawnSubmode) {
                Text("Application").tag(SpawnSubmode.application)
                Text("Program").tag(SpawnSubmode.program)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
        .padding([.horizontal, .top])
    }

    @ViewBuilder
    private func applicationSpawnPane(for device: Device) -> some View {
        if loadingApplications {
            ZStack {
                Color.clear
                VStack(spacing: 8) {
                    ProgressView("Enumerating applications…")
                    Text("Querying \(device.name)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        } else if let applicationError {
            ZStack {
                Color.clear
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                        .opacity(0.8)

                    Text("Failed to Enumerate Applications")
                        .font(.headline)

                    Text(applicationError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding()
            }
        } else if applications.isEmpty {
            ZStack {
                Color.clear
                VStack(spacing: 8) {
                    Image(systemName: "apps.iphone")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .opacity(0.6)

                    Text("No Applications")
                        .font(.headline)

                    Text(
                        "This device did not report any launchable applications. On some platforms application spawning is not supported; use Program instead."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                }
                .padding()
            }
        } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Filter by name or identifier", text: $applicationSearchText)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            #if canImport(UIKit)
                                .textInputAutocapitalization(.never)
                            #endif
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    List(filteredApplications, id: \.identifier) { app in
                        Button {
                            selectedApplicationIdentifier = app.identifier
                        } label: {
                            HStack(spacing: 8) {
                                if let firstIcon = app.icons.last {
                                    firstIcon.swiftUIImage
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 24, height: 24)
                                        .cornerRadius(4)
                                } else {
                                    IconPlaceholderView(
                                        seed: app.identifier,
                                        displayName: app.name,
                                        cornerRadius: 4
                                    )
                                    .frame(width: 24, height: 24)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.identifier)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let pid = app.pid {
                                    Text("Running (PID \(pid))")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedApplicationIdentifier == app.identifier
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                }

                Divider()

                Form {
                    Section(isExpanded: $appArgumentsExpanded) {
                        TextField("Arguments (optional)", text: $appArgumentsText, axis: .vertical)
                            .lineLimit(1...3)
                        Text("Arguments can be passed to apps too, but are not supported on all targets.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Launch Arguments")
                    }

                    Section(isExpanded: $appEnvExpanded) {
                        EnvEditor(entries: $appEnvEntries)
                        Text("Environment variables are added on top of the default environment.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Environment")
                    }

                    Section(isExpanded: $appWorkingDirExpanded) {
                        TextField("Working directory (optional)", text: $appWorkingDirectory)
                            #if canImport(UIKit)
                                .textInputAutocapitalization(.never)
                            #endif
                            .disableAutocorrection(true)
                        Text("Use an absolute path on the target device, e.g. /var/mobile.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Working Directory")
                    }

                    Section(isExpanded: $appExecutionExpanded) {
                        StdioPicker(selection: $appStdio)

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: $appAutoResume) {
                                Text("Automatically resume after instruments load")
                            }
                            Text("When turned off, the process will remain paused after spawn until you resume it from Luma.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Execution")
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @ViewBuilder
    private func programSpawnPane(for device: Device) -> some View {
        VStack(spacing: 0) {
            Form {
                Section("Program") {
                    TextField("Absolute program path", text: $programPath)
                        #if canImport(UIKit)
                            .textInputAutocapitalization(.never)
                        #endif
                        .disableAutocorrection(true)
                    Text("Provide an absolute path on the target device, e.g. /usr/bin/foo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Arguments") {
                    TextField("Arguments (optional)", text: $programArgumentsText, axis: .vertical)
                        .lineLimit(1...3)
                    Text("Space-separated arguments. Shell-style quoting may be supported in a future version.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Environment") {
                    EnvEditor(entries: $programEnvEntries)
                    Text("Environment variables are added on top of the default environment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Working Directory") {
                    TextField("Working directory (optional)", text: $programWorkingDirectory)
                        #if canImport(UIKit)
                            .textInputAutocapitalization(.never)
                        #endif
                        .disableAutocorrection(true)
                }

                Section("Execution") {
                    StdioPicker(selection: $programStdio)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $programAutoResume) {
                            Text("Automatically resume after instruments load")
                        }
                        Text("When turned off, the process will remain paused after spawn until you resume it from Luma.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task(id: device.id) {
            await loadProcesses(for: device)
        }
    }

    @ViewBuilder
    private func processDetailPane(for device: Device) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if loadingProcesses {
                ZStack {
                    Color.clear
                    VStack(spacing: 8) {
                        ProgressView("Enumerating processes…")
                        Text("Querying \(device.name)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            } else if let processError {
                ZStack {
                    Color.clear
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.yellow)
                            .opacity(0.8)

                        Text("Failed to Enumerate Processes")
                            .font(.headline)

                        Text(processError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding()
                }
            } else if processes.isEmpty {
                ZStack {
                    Color.clear
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .opacity(0.6)

                        Text("No Processes")
                            .font(.headline)

                        Text("No processes were returned by this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Filter by process name", text: $processSearchText)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            #if canImport(UIKit)
                                .textInputAutocapitalization(.never)
                            #endif
                            .focused($focusedField, equals: .processSearch)
                            .onKeyPress(.downArrow) {
                                if selectedProcessPID == nil,
                                    let first = filteredProcesses.first
                                {
                                    selectedProcessPID = first.pid
                                }
                                focusedField = .processList
                                return .handled
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ScrollViewReader { proxy in
                        List(filteredProcesses, id: \.pid, selection: $selectedProcessPID) { proc in
                            HStack(spacing: 8) {
                                if let firstIcon = proc.icons.last {
                                    firstIcon.swiftUIImage
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 24, height: 24)
                                        .cornerRadius(4)
                                } else {
                                    IconPlaceholderView(
                                        seed: proc.name,
                                        displayName: proc.name,
                                        cornerRadius: 4
                                    )
                                    .frame(width: 24, height: 24)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proc.name)
                                    Text("PID \(proc.pid)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let id = pickerState?.lastSelectedProcessName,
                                    id == proc.name
                                {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .tag(proc.pid)
                            .onTapGesture {
                                attach(to: device, process: proc)
                            }
                        }
                        .focused($focusedField, equals: .processList)
                        .onKeyPress(.return) {
                            guard
                                focusedField == .processList,
                                let pid = selectedProcessPID,
                                let proc = filteredProcesses.first(where: { $0.pid == pid })
                            else {
                                return .ignored
                            }
                            attach(to: device, process: proc)
                            return .handled
                        }
                        .onAppear {
                            if let targetName = pickerState?.lastSelectedProcessName,
                                let target = processes.first(where: { $0.name == targetName })
                            {
                                selectedProcessPID = target.pid
                                proxy.scrollTo(target.pid, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .task(id: device.id) {
            await loadProcesses(for: device)
        }
    }

    private var filteredProcesses: [ProcessDetails] {
        if processSearchText.isEmpty {
            return processes
        } else {
            return processes.filter {
                $0.name.localizedCaseInsensitiveContains(processSearchText)
            }
        }
    }

    private var filteredApplications: [ApplicationDetails] {
        if applicationSearchText.isEmpty {
            return applications
        } else {
            return applications.filter {
                $0.name.localizedCaseInsensitiveContains(applicationSearchText)
                    || $0.identifier.localizedCaseInsensitiveContains(applicationSearchText)
            }
        }
    }

    private func triggerSpawn() {
        guard let device = selectedDevice else { return }

        switch spawnSubmode {
        case .application:
            guard let identifier = selectedApplicationIdentifier,
                let app = applications.first(where: { $0.identifier == identifier })
            else { return }
            let config = SpawnConfig(
                target: .application(identifier: app.identifier, name: app.name),
                arguments: parseArguments(from: appArgumentsText),
                environment: buildEnvironment(from: appEnvEntries),
                workingDirectory: appWorkingDirectory.nilIfBlank,
                stdio: appStdio,
                autoResume: appAutoResume
            )
            onSpawn(device, config)
        case .program:
            let config = SpawnConfig(
                target: .program(path: programPath),
                arguments: parseArguments(from: programArgumentsText),
                environment: buildEnvironment(from: programEnvEntries),
                workingDirectory: programWorkingDirectory.nilIfBlank,
                stdio: programStdio,
                autoResume: programAutoResume
            )
            onSpawn(device, config)
        }

        dismiss()
    }

    private func attach(to device: Device, process: ProcessDetails) {
        pickerState?.lastSelectedProcessName = process.name
        onAttach(device, process)
        dismiss()
    }

    private func parseArguments(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func buildEnvironment(from entries: [EnvEntry]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = entry.value
        }
        return result
    }

    private func loadProcesses(for device: Device) async {
        loadingProcesses = true
        processes = []
        processError = nil
        defer { loadingProcesses = false }

        do {
            let procs = try await device.enumerateProcesses(scope: .full)

            processes = procs.sorted {
                let aHasIcon = !$0.icons.isEmpty
                let bHasIcon = !$1.icons.isEmpty

                if aHasIcon != bHasIcon {
                    return aHasIcon
                }

                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            processError = nil
        } catch {
            processes = []
            processError = error.localizedDescription
        }
    }

    private func loadApplications(for device: Device) async {
        loadingApplications = true
        applications = []
        applicationError = nil
        defer { loadingApplications = false }

        do {
            let apps = try await device.enumerateApplications()

            applications = apps.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            applicationError = nil
        } catch {
            applicationError = error.localizedDescription
            applications = []
        }
    }

    @ViewBuilder
    private func deviceListPane() -> some View {
        switch store.discoveryState {
        case .discovering:
            discoveringView

        case .ready:
            if store.devices.isEmpty {
                emptyDevicesView
            } else {
                deviceListWithHeaderView
            }
        }
    }

    private var discoveringView: some View {
        ZStack {
            Color.clear
            VStack(alignment: .leading, spacing: 12) {
                ProgressView("Searching for devices…")
                    .controlSize(.small)

                Text("Connect a device or add a remote target.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }

    private var emptyDevicesView: some View {
        VStack(spacing: 12) {
            deviceListHeaderView

            ZStack {
                Color.clear
                ContentUnavailableView(
                    "No Devices",
                    systemImage: "ipad.and.iphone",
                    description: Text("Connect a device or add a remote target to get started.")
                )
            }
        }
    }

    private var deviceListWithHeaderView: some View {
        VStack(spacing: 0) {
            deviceListHeaderView

            List(selection: $selectedDeviceID) {
                ForEach(store.devices, id: \.id) { device in
                HStack(spacing: 8) {
                    if let icon = device.icon {
                        icon.swiftUIImage
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .cornerRadius(4)
                    } else {
                        defaultDeviceIcon()
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(device.id)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    if let config = remoteConfigs.first(where: { $0.runtimeDeviceID == device.id }) {
                        Button(role: .destructive) {
                            removeRemote(config: config)
                        } label: {
                            Label("Remove Remote Device", systemImage: "trash")
                        }
                    }
                }
                }
            }
            .modifier(CompactGroupedList(isCompactWidth: isCompactWidth))
        }
        .modifier(CompactGroupedBackground(isCompactWidth: isCompactWidth))
    }

    private var deviceListHeaderView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            deviceListHeaderLeading

            if store.discoveryState == .discovering {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer()

            Button {
                showingAddRemoteSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add Remote…")
            .help("Add a remote frida-server or portal")
        }
        .padding(.horizontal, deviceListHeaderHorizontalPadding)
        .padding(.top, isCompactWidth ? 0 : 12)
        .padding(.bottom, isCompactWidth ? 16 : 8)
    }

    @ViewBuilder
    private var deviceListHeaderLeading: some View {
        if isCompactWidth {
            Text(discoveryHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Devices")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private var discoveryHelpText: String {
        switch store.discoveryState {
        case .discovering:
            return "Searching for locally connected and remote targets…"
        case .ready:
            return "Pick a device to attach to a running process or spawn a new one."
        }
    }

    private var deviceListHeaderHorizontalPadding: CGFloat {
        #if canImport(UIKit)
            return isCompactWidth ? 20 : 16
        #else
            return 12
        #endif
    }

    @ViewBuilder
    private func addRemoteSheet() -> some View {
        #if canImport(UIKit)
            addRemoteSheetIOS
        #else
            addRemoteSheetMac
        #endif
    }

    #if canImport(UIKit)
    private var addRemoteSheetIOS: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("hostname:port", text: $remoteAddress)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("Address")
                } footer: {
                    Text("Enter the address of a frida-server or portal.")
                }

                Section("TLS Certificate") {
                    TextField("PEM-encoded (optional)", text: $remoteCertificate, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section {
                    DisclosureGroup("Advanced Options", isExpanded: $showingAdvancedRemoteOptions) {
                        TextField("Origin", text: $remoteOrigin)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        TextField("Bearer / auth token", text: $remoteToken)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        TextField("Keepalive seconds", text: $remoteKeepalive)
                            .keyboardType(.numberPad)
                    }
                }

                if let addRemoteError {
                    Section {
                        Text(addRemoteError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Remote Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelAddRemote() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await addRemote() }
                    }
                    .disabled(remoteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

    #if !canImport(UIKit)
    private var addRemoteSheetMac: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Remote Device")
                    .font(.headline)

                Text("Enter the address of a frida-server or portal.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                labeledTextField(
                    "Address",
                    placeholder: "hostname:port",
                    text: $remoteAddress
                )

                labeledTextField(
                    "TLS certificate (optional)",
                    placeholder: "PEM-encoded certificate",
                    text: $remoteCertificate,
                    multiline: true
                )

                DisclosureGroup(
                    isExpanded: $showingAdvancedRemoteOptions,
                    content: {
                        VStack(spacing: 8) {
                            labeledTextField(
                                "Origin (optional)",
                                placeholder: "Origin",
                                text: $remoteOrigin
                            )

                            labeledTextField(
                                "Token (optional)",
                                placeholder: "Bearer / auth token",
                                text: $remoteToken
                            )

                            labeledTextField(
                                "Keepalive Interval (optional)",
                                placeholder: "Seconds",
                                text: $remoteKeepalive
                            )
                        }
                        .padding(.top, 8)
                    },
                    label: {
                        Text("Advanced Options")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                )

                if let addRemoteError {
                    Text(addRemoteError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        cancelAddRemote()
                    }
                    Button("Add") {
                        Task {
                            await addRemote()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 420)
    }
    #endif

    @ViewBuilder
    private func labeledTextField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        multiline: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)

            Group {
                if multiline {
                    TextField(placeholder, text: text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3, reservesSpace: true)
                } else {
                    TextField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                }
            }
            #if canImport(UIKit)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
            #endif
        }
    }

    private func cancelAddRemote() {
        showingAddRemoteSheet = false
        clearRemoteForm()
    }

    private func clearRemoteForm() {
        remoteAddress = ""
        remoteCertificate = ""
        remoteOrigin = ""
        remoteToken = ""
        remoteKeepalive = ""
        showingAdvancedRemoteOptions = false
        addRemoteError = nil
    }

    private func addRemote() async {
        let address = remoteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let certificate = remoteCertificate.isEmpty ? nil : remoteCertificate
        let origin = remoteOrigin.isEmpty ? nil : remoteOrigin
        let token = remoteToken.isEmpty ? nil : remoteToken
        let keepalive: Int? = {
            let trimmed = remoteKeepalive.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return Int(trimmed)
        }()

        guard !address.isEmpty else {
            addRemoteError = "Address is required."
            return
        }

        addRemoteError = nil

        do {
            _ = try await deviceManager.addRemoteDevice(
                address: address,
                certificate: certificate,
                origin: origin,
                token: token,
                keepaliveInterval: keepalive
            )

            let config = LumaCore.RemoteDeviceConfig(
                address: address,
                certificate: certificate,
                origin: origin,
                token: token,
                keepaliveInterval: keepalive
            )
            remoteConfigs.append(config)

            showingAddRemoteSheet = false
            clearRemoteForm()
        } catch {
            addRemoteError = error.localizedDescription
        }
    }

    private func removeRemote(config: LumaCore.RemoteDeviceConfig) {
        remoteConfigs.removeAll { $0.id == config.id }

        Task {
            try? await deviceManager.removeRemoteDevice(address: config.address)
        }
    }

    @ViewBuilder
    private func defaultDeviceIcon(size: CGFloat = 24) -> some View {
        Image(systemName: "ipad.and.iphone")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
            .opacity(0.6)
            .cornerRadius(4)
    }

    struct EnvEntry: Identifiable, Hashable {
        let id: UUID
        var key: String
        var value: String

        init(id: UUID = UUID(), key: String, value: String) {
            self.id = id
            self.key = key
            self.value = value
        }
    }

    struct EnvEditor: View {
        @Binding var entries: [EnvEntry]

        var body: some View {
            VStack(spacing: 4) {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        TextField("KEY", text: $entry.key)
                            #if canImport(UIKit)
                                .textInputAutocapitalization(.never)
                            #endif
                            .disableAutocorrection(true)
                            .frame(minWidth: 80)

                        Text("=")
                            .foregroundStyle(.secondary)

                        TextField("value", text: $entry.value)
                            #if canImport(UIKit)
                                .textInputAutocapitalization(.never)
                            #endif
                            .disableAutocorrection(true)

                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this variable")
                    }
                }

                Button {
                    entries.append(EnvEntry(key: "", value: ""))
                } label: {
                    Label("Add Variable", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
        }
    }

    struct StdioPicker: View {
        @Binding var selection: Stdio

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Standard I/O", selection: $selection) {
                    Text("Inherit").tag(Stdio.inherit)
                    Text("Pipe to Luma").tag(Stdio.pipe)
                }
                .pickerStyle(.segmented)

                Text(footerText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        private var footerText: String {
            switch selection {
            case .inherit:
                return "Use the target’s default stdin/stdout/stderr behavior."
            case .pipe:
                return "Capture output via device events and allow sending input from Luma."
            @unknown default:
                return ""
            }
        }
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CompactGroupedBackground: ViewModifier {
    let isCompactWidth: Bool

    func body(content: Content) -> some View {
        #if canImport(UIKit)
            if isCompactWidth {
                content.background(
                    Color(UIColor.systemGroupedBackground)
                        .ignoresSafeArea()
                )
            } else {
                content
            }
        #else
            content
        #endif
    }
}

private struct CompactGroupedList: ViewModifier {
    let isCompactWidth: Bool

    func body(content: Content) -> some View {
        #if canImport(UIKit)
            if isCompactWidth {
                content.scrollContentBackground(.hidden)
            } else {
                content
            }
        #else
            content
        #endif
    }
}
