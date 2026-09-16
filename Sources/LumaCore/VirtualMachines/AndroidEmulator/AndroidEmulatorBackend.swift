import Foundation

#if os(macOS) || os(Linux) || os(Windows)

/// Attaches Frida's barebone backend to the Android emulator: it launches an AVD the developer
/// already created in Android Studio with a GDB stub and instruments the hosting QEMU so the
/// stub becomes usable, then injects the agent into the guest kernel.
@MainActor
public final class AndroidEmulatorBackend: VirtualMachineBackend {
    public let id = "android-emulator"
    public let name = "Android Emulator"

    public static let avdParameterID = "avd"

    /// Frida instruments the emulator's QEMU through a gdbstub shim that reaches for an aarch64
    /// export, so an AVD on any other ABI cannot be injected into however well it boots.
    private static let instrumentableArchitectures: [VirtualMachineArchitecture] = [.arm64]

    public init() {
    }

    public var templates: [VirtualMachineTemplate] {
        let avds = AndroidEmulatorSDK.listAVDs()
        return Self.instrumentableArchitectures.map { architecture in
            let options = avds
                .filter { $0.architecture == architecture }
                .map { VirtualMachineParameterOption(id: $0.name, name: $0.name) }
            return VirtualMachineTemplate(
                id: "android-emulator.avd.\(architecture.rawValue)",
                backendID: id,
                name: "Android Emulator",
                summary: """
                    An AVD created in Android Studio, booted with a GDB stub. Frida instruments the \
                    emulator's QEMU to make the stub usable, mines the kernel image for its symbols, \
                    and injects the agent into the guest kernel.
                    """,
                iconName: "android",
                operatingSystem: .android,
                architecture: architecture,
                agentFlavor: BareboneAgentFlavor(kernel: .linux, architecture: architecture),
                parameters: [
                    VirtualMachineParameter(
                        id: Self.avdParameterID,
                        name: "Virtual device",
                        kind: .choice(options: options, default: options.first?.id ?? "")
                    )
                ]
            )
        }
    }

    public func availability(for template: VirtualMachineTemplate) -> VirtualMachineAvailability {
        guard AndroidEmulatorSDK.emulator != nil else {
            return .unavailable(reason: "The Android SDK emulator is not installed")
        }
        guard AndroidEmulatorSDK.adb != nil else {
            return .unavailable(reason: "The Android SDK platform-tools (adb) are not installed")
        }
        let avds = AndroidEmulatorSDK.listAVDs()
        guard !avds.isEmpty else {
            return .unavailable(reason: "No AVDs found; create one in Android Studio")
        }
        guard avds.contains(where: { $0.architecture == template.architecture }) else {
            let found = Set(avds.map(\.architecture.displayName)).sorted().joined(separator: ", ")
            return .unavailable(
                reason: """
                    Frida can only instrument \(template.architecture.displayName) AVDs, and the ones \
                    installed are \(found). Create one in Android Studio.
                    """)
        }
        return .available
    }

    public func launch(_ request: VirtualMachineLaunchRequest) async throws -> any VirtualMachine {
        guard let emulator = AndroidEmulatorSDK.emulator, let adb = AndroidEmulatorSDK.adb else {
            throw VirtualMachineError.launchFailed(reason: "The Android SDK emulator is not installed")
        }
        guard let avdName = request.text(Self.avdParameterID), !avdName.isEmpty else {
            throw VirtualMachineError.launchFailed(reason: "No AVD was chosen")
        }
        guard let avd = AndroidEmulatorSDK.listAVDs().first(where: { $0.name == avdName }) else {
            throw VirtualMachineError.launchFailed(reason: "AVD \(avdName) was not found")
        }
        guard Self.instrumentableArchitectures.contains(avd.architecture) else {
            throw VirtualMachineError.launchFailed(
                reason: "AVD \(avdName) is \(avd.architecture.displayName), which Frida cannot instrument")
        }

        let machine = AndroidEmulatorMachine(
            emulator: emulator, adb: adb, avd: avd, request: request)
        try await machine.start()
        return machine
    }
}

#endif
