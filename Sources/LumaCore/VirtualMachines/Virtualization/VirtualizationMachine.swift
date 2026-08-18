import Foundation
import Observation

#if canImport(Virtualization)
import Virtualization

@Observable
@MainActor
@available(macOS 13, *)
final class VirtualizationMachine: NSObject, VirtualMachine {
    let id: UUID
    let name: String
    let template: VirtualMachineTemplate
    private(set) var state: VirtualMachineState = .starting
    private(set) var display: VirtualMachineDisplay?
    private(set) var debugStub: BareboneDebugStub?
    private(set) var agentTransport: BareboneAgentTransport?

    var kernelImage: URL? {
        guard template.id == VirtualizationTemplate.macOS else {
            return try? VirtualizationLinuxImage(request: request).symbols
        }
        return bundle.kernelImage
    }

    var capabilities: VirtualMachineCapabilities {
        guard #available(macOS 14, *), guest?.canPause == true else { return [.liveDisplay, .input] }
        return [.liveDisplay, .input, .snapshot]
    }

    private let request: VirtualMachineLaunchRequest
    private let bundle: VirtualizationBundle
    private let socketDirectory = GuestSocketDirectory.make()
    private var guest: VZVirtualMachine?
    private var hostlink: VirtualizationVsockBridge?

    init(request: VirtualMachineLaunchRequest) {
        self.id = request.id
        self.name = request.name
        self.template = request.template
        self.request = request
        self.bundle = VirtualizationBundle(directory: request.storageDirectory)
    }

    func start() async throws {
        do {
            let guest = try await liveGuest()

            if request.resumesFromReadySnapshot, #available(macOS 14, *), bundle.hasSavedState {
                try await guest.restoreMachineStateFrom(url: bundle.savedState)
                try await guest.resume()
            } else {
                try await guest.start()
            }

            display = .virtualizationGuest(guest)
            debugStub = .virtualization(pid: UInt(getpid()))
            agentTransport = try openHostlink(on: guest)
            state = .running
        } catch {
            await shutDown()
            let failure = VirtualMachineError.launchFailure(error.localizedDescription, from: error)
            state = .failed(reason: failure.reason)
            throw failure
        }
    }

    private func liveGuest() async throws -> VZVirtualMachine {
        if let guest {
            return guest
        }

        let configuration = try await makeConfiguration()
        try configuration.validate()

        let guest = VZVirtualMachine(configuration: configuration)
        guest.delegate = self
        self.guest = guest

        return guest
    }

    /// A macOS guest is installed once and then started; a Linux guest is
    /// handed its kernel every time.
    private func makeConfiguration() async throws -> VZVirtualMachineConfiguration {
        guard template.id == VirtualizationTemplate.macOS else {
            return try VirtualizationLinuxImage(request: request).makeConfiguration(
                memory: request.number(VirtualizationParameter.memory) ?? 2048,
                processors: request.number(VirtualizationParameter.processors) ?? 2
            )
        }

        if !bundle.isInstalled {
            try await install()
        }
        return try bundle.makeConfiguration(
            memory: request.number(VirtualizationParameter.memory) ?? 8192,
            processors: request.number(VirtualizationParameter.processors) ?? 4
        )
    }

    private func install() async throws {
        guard let image = request.text(VirtualizationParameter.restoreImage), !image.isEmpty else {
            throw VirtualMachineError.launchFailed(reason: "No restore image was chosen")
        }

        let restoreImage = try await VZMacOSRestoreImage.image(from: URL(fileURLWithPath: image))
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VirtualMachineError.launchFailed(reason: "This Mac cannot run what that restore image carries")
        }

        try bundle.prepare(
            hardwareModel: requirements.hardwareModel,
            diskSizeInGigabytes: request.number(VirtualizationParameter.diskSize) ?? 64
        )
        try bundle.keepKernelImage(from: URL(fileURLWithPath: image))

        let configuration = try bundle.makeConfiguration(
            memory: max(request.number(VirtualizationParameter.memory) ?? 8192, Int(requirements.minimumSupportedMemorySize / (1024 * 1024))),
            processors: max(request.number(VirtualizationParameter.processors) ?? 4, requirements.minimumSupportedCPUCount)
        )
        try configuration.validate()

        let guest = VZVirtualMachine(configuration: configuration)
        self.guest = guest
        display = .virtualizationGuest(guest)

        let installer = VZMacOSInstaller(virtualMachine: guest, restoringFromImageAt: URL(fileURLWithPath: image))
        let progress = installer.progress.observe(
            \Progress.fractionCompleted,
            options: [.initial, .new]
        ) { [weak self] (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.state = .installing(fraction: fraction) }
        }
        defer { progress.invalidate() }

        try await installer.install()
        self.guest = nil
        display = nil
    }

    private func openHostlink(on guest: VZVirtualMachine) throws -> BareboneAgentTransport? {
        guard let socketDevice = guest.socketDevices.first as? VZVirtioSocketDevice else { return nil }

        let bridge = VirtualizationVsockBridge(
            socketPath: socketDirectory.appendingPathComponent("hostlink.sock"),
            port: Self.hostlinkPort,
            device: socketDevice
        )
        try bridge.start()
        hostlink = bridge

        return .vsock(socketPath: bridge.socketPath, port: UInt(Self.hostlinkPort))
    }

    func captureReadySnapshot() async throws {
        guard #available(macOS 14, *), let guest else {
            throw VirtualMachineError.snapshotFailed(reason: "This guest cannot be snapshotted")
        }

        state = .capturingSnapshot
        defer { state = .running }

        try await guest.pause()
        try await guest.saveMachineStateTo(url: bundle.savedState)
        try await guest.resume()
    }

    func restoreReadySnapshot() async throws {
        guard #available(macOS 14, *), let guest, bundle.hasSavedState else {
            throw VirtualMachineError.snapshotFailed(reason: "There is nothing to go back to")
        }

        state = .restoringSnapshot
        defer { state = .running }

        // A guest is restored from a standstill, not from a pause.
        if guest.canRequestStop {
            try await guest.stop()
        }
        try await guest.restoreMachineStateFrom(url: bundle.savedState)
        try await guest.resume()
    }

    func discardReadySnapshot() async throws {
        try? FileManager.default.removeItem(at: bundle.savedState)
    }

    func shutDown() async {
        hostlink?.stop()
        hostlink = nil
        try? FileManager.default.removeItem(at: socketDirectory)

        if let guest, guest.canRequestStop {
            try? await guest.stop()
        }
        guest = nil

        display = nil
        debugStub = nil
        agentTransport = nil
        state = .stopped
    }

    private static let hostlinkPort: UInt32 = 1339
}

@available(macOS 13, *)
extension VirtualizationMachine: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in state = .stopped }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Swift.Error) {
        Task { @MainActor in state = .failed(reason: error.localizedDescription) }
    }
}

#endif
