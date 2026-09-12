import Foundation

#if os(macOS)

/// Locates the Android SDK's emulator and the AVDs a developer already made in Android Studio,
/// and resolves the kernel image each AVD boots -- the barebone backend mines that image for the
/// kernel's symbols, so no System.map need be supplied.
enum AndroidEmulatorSDK {
    struct AVD: Sendable, Equatable {
        let name: String
        let kernelImage: URL
    }

    static var root: URL? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let path = environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk", isDirectory: true)
        return directoryExists(fallback) ? fallback : nil
    }

    static var emulator: URL? {
        guard let root else { return nil }
        let candidate = root.appendingPathComponent("emulator/emulator")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static var adb: URL? {
        guard let root else { return nil }
        let candidate = root.appendingPathComponent("platform-tools/adb")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static func listAVDs() -> [AVD] {
        guard let emulator else { return [] }
        guard let listing = run(emulator, ["-list-avds"]) else { return [] }
        var result: [AVD] = []
        for line in listing.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if let kernel = kernelImage(for: name) {
                result.append(AVD(name: name, kernelImage: kernel))
            }
        }
        return result
    }

    /// An AVD's config names the system image it boots under `image.sysdir.1`; the kernel sits
    /// beside that image as `kernel-ranchu`. A config may also pin `kernel.path` outright. The
    /// AVD's directory is not its name plus ".avd" -- the `<name>.ini` file's `path=` says where
    /// it really is.
    private static func kernelImage(for avd: String) -> URL? {
        guard let root else { return nil }

        let pointer = avdHome.appendingPathComponent("\(avd).ini")
        guard let pointerText = try? String(contentsOf: pointer, encoding: .utf8),
            let avdDirectory = value(of: "path", in: pointerText)
        else { return nil }

        let config = URL(fileURLWithPath: avdDirectory, isDirectory: true).appendingPathComponent("config.ini")
        guard let settings = try? String(contentsOf: config, encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        for line in settings.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        if let explicit = values["kernel.path"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let sysdir = values["image.sysdir.1"], !sysdir.isEmpty else { return nil }
        for name in ["kernel-ranchu", "kernel-ranchu-64", "kernel-qemu"] {
            let candidate = root.appendingPathComponent(sysdir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static var avdHome: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ANDROID_AVD_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd", isDirectory: true)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Wait on a semaphore rather than waitUntilExit(), which spins the runloop and re-enters
        // SwiftUI's update cycle when this is read from a view.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        return String(data: data, encoding: .utf8)
    }
}

#endif
