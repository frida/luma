import Foundation

#if canImport(Virtualization)
import Virtualization

@MainActor
public final class VirtualizationBackend: VirtualMachineBackend {
    public let id = "virtualization"
    public let name = "Virtualization"

    public init() {
    }



    public var templates: [VirtualMachineTemplate] {
        [
            VirtualMachineTemplate(
                id: VirtualizationTemplate.macOS,
                backendID: id,
                name: "macOS",
                summary: """
                    A macOS guest run by Virtualization.framework. The first boot installs it from a restore image, \
                    which takes a while; every boot after that starts what was installed. Frida injects the xnu agent \
                    into its kernel.
                    """,
                iconName: "xnu",
                operatingSystem: .macOS,
                architecture: .arm64,
                agentFlavor: .xnuArm64,
                parameters: [
                    VirtualMachineParameter(
                        id: VirtualizationParameter.restoreImage,
                        name: "Restore image",
                        kind: .filePath(extensions: ["ipsw"])
                    ),
                    VirtualMachineParameter(
                        id: VirtualizationParameter.diskSize,
                        name: "Disk",
                        kind: .number(default: 64, min: 32, max: 2048, unit: "GB")
                    ),
                    VirtualMachineParameter(
                        id: VirtualizationParameter.memory,
                        name: "Memory",
                        kind: .number(default: 8192, min: 2048, max: 65536, unit: "MB")
                    ),
                    VirtualMachineParameter(
                        id: VirtualizationParameter.processors,
                        name: "Processors",
                        kind: .number(default: 4, min: 1, max: 16, unit: nil)
                    ),
                ]
            ),
        ]
    }

    public func availability(for template: VirtualMachineTemplate) -> VirtualMachineAvailability {
        guard #available(macOS 13, *) else {
            return .unavailable(reason: "A virtual machine of this kind needs macOS 13 or newer")
        }
        guard isAppleSilicon else {
            return .unavailable(reason: "Virtualization.framework runs Apple silicon guests only")
        }
        return .available
    }

    public func launch(_ request: VirtualMachineLaunchRequest) async throws -> any VirtualMachine {
        guard #available(macOS 13, *) else {
            throw VirtualMachineError.launchFailed(reason: "A macOS guest needs macOS 13 or newer")
        }

        let machine = VirtualizationMachine(request: request)
        try await machine.start()
        return machine
    }

    private var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

enum VirtualizationTemplate {
    static let macOS = "virtualization.macos"
    static let linux = "virtualization.linux"
}

enum VirtualizationParameter {
    static let restoreImage = "restore-image"
    static let kernel = "kernel"
    static let ramdisk = "ramdisk"
    static let disk = "disk"
    static let symbols = "symbols"
    static let commandLine = "command-line"
    static let diskSize = "disk-size"
    static let memory = "memory"
    static let processors = "processors"
}

#endif
