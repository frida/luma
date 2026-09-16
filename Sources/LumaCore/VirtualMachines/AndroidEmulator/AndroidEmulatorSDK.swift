import Foundation

#if os(macOS) || os(Linux) || os(Windows)

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
        for fallback in defaultRoots where directoryExists(fallback) {
            return fallback
        }
        return nil
    }

    static var emulator: URL? {
        tool(at: "emulator", named: "emulator")
    }

    static var adb: URL? {
        tool(at: "platform-tools", named: "adb")
    }

    private static func tool(at directory: String, named name: String) -> URL? {
        guard let root else { return nil }
        let candidate = root
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(name + executableSuffix)
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private static var executableSuffix: String {
        #if os(Windows)
        ".exe"
        #else
        ""
        #endif
    }

    private static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return [home.appendingPathComponent("Library/Android/sdk", isDirectory: true)]
        #elseif os(Windows)
        let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return [localAppData?.appendingPathComponent("Android/Sdk", isDirectory: true)].compactMap { $0 }
        #else
        return [home.appendingPathComponent("Android/Sdk", isDirectory: true)]
        #endif
    }

    static func listAVDs() -> [AVD] {
        guard let emulator else { return [] }
        guard let listing = run(emulator, ["-list-avds"]) else { return [] }
        var result: [AVD] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let config = URL(fileURLWithPath: nativePath(avdDirectory), isDirectory: true)
            .appendingPathComponent("config.ini")
        guard let settings = try? String(contentsOf: config, encoding: .utf8) else { return nil }

        var values: [String: String] = [:]
        for line in settings.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                values[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                    parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let explicit = values["kernel.path"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: nativePath(explicit))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let sysdir = values["image.sysdir.1"], !sysdir.isEmpty else { return nil }
        for name in ["kernel-ranchu", "kernel-ranchu-64", "kernel-qemu"] {
            let candidate = root.appendingPathComponent(nativePath(sysdir)).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// An AVD config on Windows spells its paths with backslashes, which URL keeps as ordinary
    /// characters rather than separators.
    private static func nativePath(_ path: String) -> String {
        #if os(Windows)
        path.replacingOccurrences(of: "\\", with: "/")
        #else
        path
        #endif
    }

    private static func value(of key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
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
        let process = ChildProcess()
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
