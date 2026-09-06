import Foundation
import Frida
import Observation

@Observable
@MainActor
public final class VirtualMachineManager {
    public private(set) var backends: [any VirtualMachineBackend] = []
    public private(set) var records: [VirtualMachineRecord] = []
    public let agents: BareboneAgentLibrary
    public let starterImages: StarterImageLibrary

    private var running: [UUID: any VirtualMachine] = [:]
    private var devices: [UUID: Device] = [:]
    private var stopping: Set<UUID> = []

    private let deviceManager: DeviceManager
    private let store: ProjectStore
    private let storageDirectory: URL

    public init(deviceManager: DeviceManager, store: ProjectStore, dataDirectory: URL) {
        self.deviceManager = deviceManager
        self.store = store
        self.storageDirectory = dataDirectory.appendingPathComponent("VirtualMachines", isDirectory: true)
        self.agents = BareboneAgentLibrary(directory: dataDirectory.appendingPathComponent("BareboneAgents", isDirectory: true))
        self.starterImages = StarterImageLibrary(
            directory: dataDirectory.appendingPathComponent("StarterImages", isDirectory: true)
        )
    }

    public func register(_ backend: any VirtualMachineBackend) {
        backends.append(backend)
    }

    public func load() {
        records = (try? store.fetchVirtualMachines()) ?? []
    }

    public var templates: [VirtualMachineTemplate] {
        backends.flatMap(\.templates).sorted { left, right in
            (left.operatingSystem, left.architecture, left.name)
                < (right.operatingSystem, right.architecture, right.name)
        }
    }

    public func availability(for template: VirtualMachineTemplate) -> VirtualMachineAvailability {
        guard let backend = backend(for: template) else {
            return .unavailable(reason: "No backend named \(template.backendID) is registered")
        }
        return backend.availability(for: template)
    }

    public func machine(for record: VirtualMachineRecord) -> (any VirtualMachine)? {
        running[record.id]
    }

    public func template(for record: VirtualMachineRecord) -> VirtualMachineTemplate? {
        templates.first { $0.id == record.templateID }
    }

    public func create(
        template: VirtualMachineTemplate,
        name: String,
        parameters: [String: VirtualMachineParameterValue],
        agentPath: URL?
    ) async throws -> any VirtualMachine {
        let record = VirtualMachineRecord(
            name: name,
            templateID: template.id,
            parameters: parameters,
            agentPath: agentPath?.path
        )
        try store.save(record)
        records.append(record)
        return try await boot(record)
    }

    public func device(for record: VirtualMachineRecord) -> Device? {
        devices[record.id]
    }

    public func device(for machine: any VirtualMachine) -> Device? {
        devices[machine.id]
    }

    public func boot(_ record: VirtualMachineRecord, resumingFromReadySnapshot: Bool = true) async throws -> any VirtualMachine {
        guard let template = template(for: record), let backend = backend(for: template) else {
            throw VirtualMachineError.launchFailed(reason: "No template named \(record.templateID) is available")
        }

        let machineDirectory = storageDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: machineDirectory, withIntermediateDirectories: true)

        let machine = try await backend.launch(
            VirtualMachineLaunchRequest(
                id: record.id,
                template: template,
                name: record.name,
                parameters: record.parameters,
                agentPath: agentPath(for: record, template: template),
                storageDirectory: machineDirectory,
                resumesFromReadySnapshot: record.hasReadySnapshot && resumingFromReadySnapshot
            )
        )
        running[record.id] = machine
        _ = try? await addBareboneDevice(for: machine)
        return machine
    }

    public func markReady(_ machine: any VirtualMachine) async throws {
        if let device = devices.removeValue(forKey: machine.id) {
            try? await deviceManager.removeBareboneDevice(device: device)
        }

        try await machine.captureReadySnapshot()

        _ = try? await addBareboneDevice(for: machine)

        guard let index = records.firstIndex(where: { $0.id == machine.id }) else { return }
        records[index].hasReadySnapshot = true
        try store.save(records[index])
    }

    public func discardReadySnapshot(_ record: VirtualMachineRecord) async throws {
        try await running[record.id]?.discardReadySnapshot()

        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].hasReadySnapshot = false
        try store.save(records[index])
    }

    private func addBareboneDevice(for machine: any VirtualMachine) async throws -> Device {
        guard let stub = machine.debugStub else {
            throw VirtualMachineError.launchFailed(reason: "The machine has no debugger to connect to")
        }

        let record = records.first { $0.id == machine.id }

        var agent: BareboneAgentConfig?
        if let record, let path = agentPath(for: record, template: machine.template), let transport = machine.agentTransport?.config {
            let image = try Data(contentsOf: path)
            agent = BareboneInjectedAgentConfig(image: [UInt8](image), transport: transport)
        }

        var image: BareboneImageConfig?
        if let kernelImage = machine.kernelImage {
            image = BareboneImageConfig(file: kernelImage.path)
        }

        let device = try await deviceManager.addBareboneDevice(
            config: BareboneConfig(
                connection: stub.connectionConfig,
                agent: agent,
                image: image,
                kernel: machine.template.variant(for: record?.parameters ?? [:]).agentFlavor?.kernel.kind
            ),
            id: Self.deviceID(for: machine.id),
            name: machine.name,
            icon: machine.template.icon
        )
        devices[machine.id] = device
        return device
    }

    static func deviceID(for machineID: UUID) -> String {
        "barebone-vm-\(machineID.uuidString)"
    }

    public func isStopping(_ record: VirtualMachineRecord) -> Bool {
        stopping.contains(record.id)
    }

    public func stop(_ record: VirtualMachineRecord) async {
        guard let machine = running[record.id], !stopping.contains(record.id) else { return }
        stopping.insert(record.id)
        defer { stopping.remove(record.id) }

        if let device = devices.removeValue(forKey: record.id) {
            try? await deviceManager.removeBareboneDevice(device: device)
        }

        await machine.shutDown()
        running.removeValue(forKey: record.id)
    }

    public func stopAll() async {
        for record in records where running[record.id] != nil {
            await stop(record)
        }
    }

    public func forget(_ record: VirtualMachineRecord) async {
        await stop(record)
        try? store.deleteVirtualMachine(id: record.id)
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: storageDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true))
    }

    private func agentPath(for record: VirtualMachineRecord, template: VirtualMachineTemplate) -> URL? {
        if let chosen = record.agentPath {
            return URL(fileURLWithPath: chosen)
        }
        return template.variant(for: record.parameters).agentFlavor.flatMap { agents.cachedPath(for: $0) }
    }

    private func backend(for template: VirtualMachineTemplate) -> (any VirtualMachineBackend)? {
        backends.first { $0.id == template.backendID }
    }
}

extension BareboneAgentTransport {
    var config: BareboneInjectingTransportConfig {
        switch self {
        case .hostlink(let qmpSocket, let bus, let fabric):
            return BareboneHostlinkTransportConfig(qmp: "unix:\(qmpSocket.path)", bus: bus, fabric: fabric.config)
        case .vsock(let socketPath, let port):
            return BareboneVsockTransportConfig(socketPath: socketPath.path, port: port)
        }
    }
}

extension BareboneHostlinkFabric {
    var config: Frida.BareboneHostlinkFabric {
        switch self {
        case .ports:
            return BareboneHostlinkPortsFabric()
        case .ecam(let base):
            return BareboneHostlinkEcamFabric(ecam: base)
        case .mmio:
            return BareboneHostlinkMmioFabric()
        }
    }
}

extension BareboneDebugStub {
    var connectionConfig: BareboneConnectionConfig {
        switch self {
        case .gdbRemote(let host, let port):
            return BareboneConnectionConfig(host: host, port: UInt(port), flavor: .gdbRemote)
        case .virtualization(let pid):
            return BareboneConnectionConfig(pid: pid, flavor: .vz)
        }
    }
}
