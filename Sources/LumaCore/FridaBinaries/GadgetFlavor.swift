public typealias GadgetLibrary = FridaBinaryLibrary<GadgetFlavor>

public enum GadgetFlavor: FridaBinaryFlavor {
    case ios
    case android(VirtualMachineArchitecture)

    public init?(system: SystemParameters) {
        guard system.access == .jailed else { return nil }
        switch system.osID {
        case "ios":
            self = .ios
        case "android":
            guard let architecture = VirtualMachineArchitecture(fridaName: system.arch) else { return nil }
            self = .android(architecture)
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .ios:
            return "iOS Gadget"
        case .android(let architecture):
            return "Android \(architecture.rawValue) Gadget"
        }
    }

    public var cachedFileName: String {
        switch self {
        case .ios:
            return "gadget-ios.dylib"
        case .android(let architecture):
            return "gadget-android-\(architecture.rawValue).so"
        }
    }

    public func assetName(version: String) -> String {
        switch self {
        case .ios:
            return "frida-gadget-\(version)-ios-universal.dylib.xz"
        case .android(let architecture):
            return "frida-gadget-\(version)-android-\(architecture.rawValue).so.xz"
        }
    }
}

extension VirtualMachineArchitecture {
    fileprivate init?(fridaName: String) {
        switch fridaName {
        case "ia32":
            self = .x86
        case "x64":
            self = .x86_64
        case "arm":
            self = .arm
        case "arm64":
            self = .arm64
        default:
            return nil
        }
    }
}
