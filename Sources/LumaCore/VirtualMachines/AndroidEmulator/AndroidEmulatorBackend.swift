import Foundation

#if os(Windows) || os(macOS) || os(Linux)

/// Attaches Frida's barebone backend to the Android emulator: it launches an AVD the developer
/// already created in Android Studio with a GDB stub and instruments the hosting QEMU so the
/// stub becomes usable, then injects the agent into the guest kernel.
@MainActor
public final class AndroidEmulatorBackend: VirtualMachineBackend {
    public let id = "android-emulator"
    public let name = "Android Emulator"

    public static let avdParameterID = "avd"

    private static let instrumentableArchitectures: [VirtualMachineArchitecture] = [.arm64, .x86_64]

    public init() {
    }

    public var templates: [VirtualMachineTemplate] {
        let options = instrumentableAVDs().map {
            VirtualMachineParameterOption(id: $0.name, name: "\($0.name) (\($0.architecture.displayName))")
        }
        return [
            VirtualMachineTemplate(
                id: "android-emulator",
                backendID: id,
                name: "Android Emulator",
                summary: """
                    An AVD created in Android Studio, booted with a GDB stub. Frida instruments the \
                    emulator's QEMU to make the stub usable, mines the kernel image for its symbols, \
                    and injects the agent into the guest kernel.
                    """,
                iconName: "android",
                operatingSystem: .android,
                variants: Self.instrumentableArchitectures.map { architecture in
                    VirtualMachineTemplateVariant(
                        architecture: architecture,
                        agentFlavor: BareboneAgentFlavor(kernel: .linux, architecture: architecture),
                        starterImages: nil
                    )
                },
                parameters: [
                    VirtualMachineParameter(
                        id: Self.avdParameterID,
                        name: "Virtual device",
                        kind: .choice(options: options, default: options.first?.id ?? "")
                    )
                ]
            )
        ]
    }

    public func availability(for template: VirtualMachineTemplate) -> VirtualMachineAvailability {
        guard AndroidEmulatorSDK.emulator != nil else {
            return .unavailable(reason: "The Android SDK emulator is not installed")
        }
        guard AndroidEmulatorSDK.adb != nil else {
            return .unavailable(reason: "The Android SDK platform-tools (adb) are not installed")
        }
        guard !instrumentableAVDs().isEmpty else {
            return .unavailable(reason: "No arm64 or x86-64 AVD found; create one in Android Studio")
        }
        return .available
    }

    public func prewarm() async {
        await AndroidEmulatorSDK.reloadAVDs()
    }

    public func resolvedParameters(
        for template: VirtualMachineTemplate,
        parameters: [String: VirtualMachineParameterValue]
    ) -> [String: VirtualMachineParameterValue] {
        guard let avdName = parameters[Self.avdParameterID]?.text,
            let avd = AndroidEmulatorSDK.listAVDs().first(where: { $0.name == avdName })
        else { return parameters }
        var resolved = parameters
        resolved[VirtualMachineTemplate.architectureParameterID] = .text(avd.architecture.rawValue)
        return resolved
    }

    private func instrumentableAVDs() -> [AndroidEmulatorSDK.AVD] {
        AndroidEmulatorSDK.listAVDs().filter { Self.instrumentableArchitectures.contains($0.architecture) }
    }

    public func launch(_ request: VirtualMachineLaunchRequest) async throws -> any VirtualMachine {
        guard let emulator = AndroidEmulatorSDK.emulator, let adb = AndroidEmulatorSDK.adb else {
            throw VirtualMachineError.launchFailed(reason: "The Android SDK emulator is not installed")
        }
        guard let avdName = request.text(Self.avdParameterID), !avdName.isEmpty else {
            throw VirtualMachineError.launchFailed(reason: "No AVD was chosen")
        }
        if AndroidEmulatorSDK.listAVDs().isEmpty {
            await AndroidEmulatorSDK.reloadAVDs()
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
