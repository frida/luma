import Foundation
import Frida

public struct BareboneAgentFlavor: Sendable, Equatable, Hashable, Codable {
    public let kernel: BareboneAgentKernel
    public let architecture: VirtualMachineArchitecture

    public static let xnuArm64 = BareboneAgentFlavor(kernel: .xnu, architecture: .arm64)
    public static let linuxArm64 = BareboneAgentFlavor(kernel: .linux, architecture: .arm64)
    public static let win9xX86 = BareboneAgentFlavor(kernel: .win9x, architecture: .x86)
    public static let winntX86 = BareboneAgentFlavor(kernel: .winnt, architecture: .x86)
    public static let winntX86_64 = BareboneAgentFlavor(kernel: .winnt, architecture: .x86_64)

    public init(kernel: BareboneAgentKernel, architecture: VirtualMachineArchitecture) {
        self.kernel = kernel
        self.architecture = architecture
    }

    public var name: String {
        "\(kernel.rawValue)-\(architecture.rawValue)"
    }

    public var assetName: String {
        "frida-barebone-agent-\(name).xz"
    }
}

public enum BareboneAgentKernel: String, Sendable, Codable {
    case xnu
    case win9x
    case winnt
    case linux

    public var kind: BareboneKernelKind {
        switch self {
        case .xnu: return .xnu
        case .win9x: return .win9x
        case .winnt: return .winnt
        case .linux: return .linux
        }
    }
}
