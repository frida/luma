import Foundation
import Frida

public struct VirtualMachineTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let backendID: String
    public let name: String
    public let summary: String
    public let iconName: String
    public let operatingSystem: VirtualMachineOperatingSystem
    public let architecture: VirtualMachineArchitecture
    public let agentFlavor: BareboneAgentFlavor?
    public let parameters: [VirtualMachineParameter]
    public let starterImages: StarterImages?

    public init(
        id: String,
        backendID: String,
        name: String,
        summary: String,
        iconName: String,
        operatingSystem: VirtualMachineOperatingSystem,
        architecture: VirtualMachineArchitecture,
        agentFlavor: BareboneAgentFlavor?,
        parameters: [VirtualMachineParameter],
        starterImages: StarterImages? = nil
    ) {
        self.id = id
        self.backendID = backendID
        self.name = name
        self.summary = summary
        self.iconName = iconName
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.agentFlavor = agentFlavor
        self.parameters = parameters
        self.starterImages = starterImages
    }

    public var icon: Icon? {
        MachineIcon.named(iconName)
    }

    public var defaultParameterValues: [String: VirtualMachineParameterValue] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.kind.defaultValue) })
    }
}

/// Declared in the order Frida names them, which is the order they are listed
/// in.
public enum VirtualMachineOperatingSystem: String, Sendable, Codable, Comparable {
    case windows
    case macOS
    case linux
    case iOS
    case android

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    private static let allCases: [Self] = [.windows, .macOS, .linux, .iOS, .android]
}

public enum VirtualMachineArchitecture: String, Sendable, Codable, Comparable {
    case x86
    case x86_64
    case arm
    case arm64

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    private static let allCases: [Self] = [.x86, .x86_64, .arm, .arm64]
}

public struct VirtualMachineParameter: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: VirtualMachineParameterKind

    public init(id: String, name: String, kind: VirtualMachineParameterKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum VirtualMachineParameterKind: Sendable, Equatable {
    case text(default: String)
    case number(default: Int, min: Int, max: Int, unit: String?)
    case filePath(extensions: [String])
    case choice(options: [VirtualMachineParameterOption], default: String)
    case toggle(default: Bool)

    var defaultValue: VirtualMachineParameterValue {
        switch self {
        case .text(let value):
            return .text(value)
        case .number(let value, _, _, _):
            return .number(value)
        case .filePath:
            return .text("")
        case .choice(_, let value):
            return .text(value)
        case .toggle(let value):
            return .toggle(value)
        }
    }
}

public struct VirtualMachineParameterOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum VirtualMachineParameterValue: Sendable, Equatable, Codable {
    case text(String)
    case number(Int)
    case toggle(Bool)

    public var text: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    public var number: Int? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var toggle: Bool? {
        guard case .toggle(let value) = self else { return nil }
        return value
    }
}
