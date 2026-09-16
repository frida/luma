import Foundation

#if canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Windows) || os(macOS) || os(Linux)

#if os(Windows)
typealias HostProcessID = DWORD
#else
typealias HostProcessID = pid_t
#endif

enum HostProcessLookup {
    static func firstProcess(named prefix: String, commandLineContaining needle: String) -> HostProcessID? {
        for candidate in processes() where candidate.name.hasPrefix(prefix) {
            if let arguments = commandLine(of: candidate.id), arguments.contains(needle) {
                return candidate.id
            }
        }
        return nil
    }

    static func isAlive(_ id: HostProcessID) -> Bool {
        #if os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, id) else { return false }
        defer { CloseHandle(handle) }
        var code: DWORD = 0
        guard GetExitCodeProcess(handle, &code) else { return false }
        return Int32(code) == STILL_ACTIVE
        #else
        return kill(id, 0) == 0
        #endif
    }

    static func terminate(_ id: HostProcessID, force: Bool) {
        #if os(Windows)
        guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, id) else { return }
        defer { CloseHandle(handle) }
        TerminateProcess(handle, 1)
        #else
        kill(id, force ? SIGKILL : SIGTERM)
        #endif
    }

    #if os(Windows)
    private static func processes() -> [(id: HostProcessID, name: String)] {
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard snapshot != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snapshot) }

        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        guard Process32FirstW(snapshot, &entry) else { return [] }

        var found: [(id: HostProcessID, name: String)] = []
        repeat {
            let name = withUnsafeBytes(of: entry.szExeFile) { raw in
                String(decodingCString: raw.bindMemory(to: WCHAR.self).baseAddress!, as: UTF16.self)
            }
            found.append((entry.th32ProcessID, name))
        } while Process32NextW(snapshot, &entry)
        return found
    }

    private static func commandLine(of id: HostProcessID) -> String? {
        let query = """
            (Get-CimInstance Win32_Process -Filter 'ProcessId = \(id)').CommandLine
            """
        return runPowerShell(query)
    }

    private static func runPowerShell(_ command: String) -> String? {
        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    #elseif os(macOS)
    private static func processes() -> [(id: HostProcessID, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, 4, nil, &size, nil, 0) != 0 { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        if sysctl(&mib, 4, &procs, &size, nil, 0) != 0 { return [] }

        return procs.map { entry in
            var entry = entry
            let name = withUnsafeBytes(of: &entry.kp_proc.p_comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            return (entry.kp_proc.p_pid, name)
        }
    }

    private static func commandLine(of id: HostProcessID) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, id]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 { return nil }
        let bytes = buffer.prefix(size).map { $0 == 0 ? UInt8(ascii: " ") : $0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    #else
    private static func processes() -> [(id: HostProcessID, name: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return entries.compactMap { entry in
            guard let id = pid_t(entry),
                let name = try? String(contentsOfFile: "/proc/\(entry)/comm", encoding: .utf8)
            else { return nil }
            return (id, name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func commandLine(of id: HostProcessID) -> String? {
        guard let raw = FileManager.default.contents(atPath: "/proc/\(id)/cmdline") else { return nil }
        return String(decoding: raw.map { $0 == 0 ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
    }
    #endif
}

#endif
