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
        try await machine.captureReadySnapshot()

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

        var agent: BareboneAgentConfig?
        if let record = records.first(where: { $0.id == machine.id }),
            let path = agentPath(for: record, template: machine.template)
        {
            agent = BareboneAgentConfig(path: path.path, transport: machine.agentTransport?.config)
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
                kernel: machine.template.agentFlavor?.kernel.kind
            ),
            name: machine.name,
            icon: machine.template.icon
        )
        devices[machine.id] = device
        return device
    }

    public func stop(_ record: VirtualMachineRecord) async {
        if let device = devices.removeValue(forKey: record.id) {
            try? await deviceManager.removeBareboneDevice(device: device)
        }

        guard let machine = running.removeValue(forKey: record.id) else { return }
        await machine.shutDown()
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
        return template.agentFlavor.flatMap { agents.cachedPath(for: $0) }
    }

    private func backend(for template: VirtualMachineTemplate) -> (any VirtualMachineBackend)? {
        backends.first { $0.id == template.backendID }
    }
}

extension BareboneAgentTransport {
    var config: BareboneTransportConfig {
        switch self {
        case .hostlink(let qmpSocket, let bus, let ecam):
            return BareboneHostlinkTransportConfig(qmp: "unix:\(qmpSocket.path)", bus: bus, ecam: ecam)
        case .vsock(let socketPath, let port):
            return BareboneVsockTransportConfig(socketPath: socketPath.path, port: port)
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
