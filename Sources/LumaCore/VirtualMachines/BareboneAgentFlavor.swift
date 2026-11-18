import Foundation
import Frida

public typealias BareboneAgentLibrary = FridaBinaryLibrary<BareboneAgentFlavor>

public struct BareboneAgentFlavor: FridaBinaryFlavor, Codable {
    public let kernel: BareboneAgentKernel
    public let architecture: VirtualMachineArchitecture

    public static let xnuArm64 = BareboneAgentFlavor(kernel: .xnu, architecture: .arm64)
    public static let linuxArm64 = BareboneAgentFlavor(kernel: .linux, architecture: .arm64)
    public static let linuxArm = BareboneAgentFlavor(kernel: .linux, architecture: .arm)
    public static let linuxX86_64 = BareboneAgentFlavor(kernel: .linux, architecture: .x86_64)
    public static let linuxX86 = BareboneAgentFlavor(kernel: .linux, architecture: .x86)
    public static let win9xX86 = BareboneAgentFlavor(kernel: .win9x, architecture: .x86)
    public static let winntX86 = BareboneAgentFlavor(kernel: .winnt, architecture: .x86)
    public static let winntX86_64 = BareboneAgentFlavor(kernel: .winnt, architecture: .x86_64)
    public static let winntArm64 = BareboneAgentFlavor(kernel: .winnt, architecture: .arm64)

    public init(kernel: BareboneAgentKernel, architecture: VirtualMachineArchitecture) {
        self.kernel = kernel
        self.architecture = architecture
    }

    public var name: String {
        "\(kernel.rawValue)-\(architecture.rawValue)"
    }

    public var displayName: String {
        "\(name) agent"
    }

    public var cachedFileName: String {
        "barebone-agent-\(name)"
    }

    public func assetName(version: String) -> String {
        "frida-barebone-agent-\(version)-\(name).xz"
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
