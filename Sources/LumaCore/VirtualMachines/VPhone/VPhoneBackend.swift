import Foundation

#if os(macOS)

@MainActor
public final class VPhoneBackend: VirtualMachineBackend {
    public let id = "vphone"
    public let name = "vphone"

    public init() {
    }

    public var templates: [VirtualMachineTemplate] {
        [
            VirtualMachineTemplate(
                id: "vphone.iphone",
                backendID: id,
                name: "iPhone",
                summary: "A virtual iPhone booted by vphone-cli. Frida injects the xnu agent into its kernel.",
                iconName: "xnu",
                operatingSystem: .iOS,
                architecture: .arm64,
                agentFlavor: .xnuArm64,
                parameters: [
                    VirtualMachineParameter(
                        id: VPhoneParameter.bundle,
                        name: "vphone-cli",
                        kind: .filePath(extensions: ["app"])
                    ),
                    VirtualMachineParameter(
                        id: VPhoneParameter.config,
                        name: "VM manifest",
                        kind: .filePath(extensions: ["plist"])
                    ),
                    VirtualMachineParameter(
                        id: VPhoneParameter.variant,
                        name: "Firmware variant",
                        kind: .choice(
                            options: VPhoneVariant.allCases.map {
                                VirtualMachineParameterOption(id: $0.rawValue, name: $0.name)
                            },
                            default: VPhoneVariant.regular.rawValue
                        )
                    ),
                ]
            )
        ]
    }

    public func availability(for template: VirtualMachineTemplate) -> VirtualMachineAvailability {
        guard #available(macOS 15, *) else {
            return .unavailable(reason: "A virtual iPhone needs macOS 15 or newer")
        }
        return .available
    }

    public func launch(_ request: VirtualMachineLaunchRequest) async throws -> any VirtualMachine {
        guard let bundle = request.text(VPhoneParameter.bundle), !bundle.isEmpty else {
            throw VirtualMachineError.launchFailed(reason: "No vphone-cli was chosen")
        }
        guard let config = request.text(VPhoneParameter.config), !config.isEmpty else {
            throw VirtualMachineError.launchFailed(reason: "No VM manifest was chosen")
        }

        let machine = VPhoneMachine(
            executable: URL(fileURLWithPath: bundle).appendingPathComponent("Contents/MacOS/vphone-cli"),
            config: URL(fileURLWithPath: config),
            variant: VPhoneVariant(rawValue: request.text(VPhoneParameter.variant) ?? "") ?? .regular,
            request: request
        )
        try await machine.start()
        return machine
    }
}

enum VPhoneParameter {
    static let bundle = "bundle"
    static let config = "config"
    static let variant = "variant"
}

enum VPhoneVariant: String, CaseIterable, Sendable {
    case patchless = "less"
    case regular
    case development = "dev"
    case jailbreak = "jb"
    case experimental = "exp"

    var name: String {
        switch self {
        case .patchless: return "Patchless"
        case .regular: return "Regular"
        case .development: return "Development"
        case .jailbreak: return "Jailbreak"
        case .experimental: return "Experimental"
        }
    }
}

#endif
