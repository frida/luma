import Foundation

@MainActor
public final class QemuBackend: VirtualMachineBackend {
    public let id = "qemu"
    public let name = "QEMU"

    public init() {
    }

    public var templates: [VirtualMachineTemplate] {
        QemuGuest.templates
    }

    public func availability(for template: VirtualMachineTemplate) -> VirtualMachineAvailability {
        guard let guest = QemuGuest.guest(for: template.id, parameters: [:]) else {
            return .unavailable(reason: "Unknown guest \(template.id)")
        }
        guard QemuExecutable.path(for: guest.emulator) != nil else {
            return .unavailable(reason: "\(guest.emulator) is not installed")
        }
        return .available
    }

    public func launch(_ request: VirtualMachineLaunchRequest) async throws -> any VirtualMachine {
        guard let guest = QemuGuest.guest(for: request.template.id, parameters: request.parameters) else {
            throw VirtualMachineError.launchFailed(reason: "Unknown guest \(request.template.id)")
        }
        guard let executable = QemuExecutable.path(for: guest.emulator) else {
            throw VirtualMachineError.launchFailed(reason: "\(guest.emulator) is not installed")
        }

        let machine = QemuMachine(guest: guest, executable: executable, request: request)
        try await machine.start()
        return machine
    }
}

enum QemuExecutable {
    static func path(for emulator: String) -> URL? {
        for directory in searchPaths {
            let candidate = directory.appendingPathComponent(emulator + executableSuffix)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static var searchPaths: [URL] {
        [bundledDirectory] + installedDirectories
    }

    private static var bundledDirectory: URL {
        Bundle.module.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("qemu", isDirectory: true)
    }

    private static var installedDirectories: [URL] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (path.split(separator: pathSeparator).map(String.init) + packageManagerPaths)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    #if os(Windows)
    private static let executableSuffix = ".exe"
    private static let pathSeparator: Character = ";"
    private static let packageManagerPaths: [String] = []
    #else
    private static let executableSuffix = ""
    private static let pathSeparator: Character = ":"
    private static let packageManagerPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    #endif
}

