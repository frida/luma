import Foundation

#if os(Windows)

import WinSDK

public final class ChildProcess: @unchecked Sendable {
    public var executableURL: URL?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?
    public var standardInput: Any?
    public var standardOutput: Any?
    public var standardError: Any?
    public var terminationHandler: ((ChildProcess) -> Void)?

    public private(set) var processIdentifier: Int32 = 0

    private let state = NSLock()
    private var process: HANDLE?
    private var exitCode: DWORD = 0

    public init() {}

    public var isRunning: Bool {
        guard let process = liveProcess else { return false }
        return WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT)
    }

    public var terminationStatus: Int32 {
        state.withLock { Int32(bitPattern: exitCode) }
    }

    public func run() throws {
        guard let executableURL else {
            throw ChildProcessError.spawnFailed(reason: "no executable was named")
        }

        var opened: [HANDLE] = []
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.hStdInput = try inherited(standardInput, writing: false, opened: &opened)
        startup.hStdOutput = try inherited(standardOutput, writing: true, opened: &opened)
        startup.hStdError = try inherited(standardError, writing: true, opened: &opened)
        defer { opened.forEach { CloseHandle($0) } }

        var spawned = PROCESS_INFORMATION()
        let commandLine = Self.quoted([executableURL.path] + (arguments ?? []))
        let block = Self.environmentBlock(environment ?? ProcessInfo.processInfo.environment)
        let directory = currentDirectoryURL?.path ?? FileManager.default.currentDirectoryPath

        let created = commandLine.withCString(encodedAs: UTF16.self) { line in
            block.withCString(encodedAs: UTF16.self) { environment in
                directory.withCString(encodedAs: UTF16.self) { directory in
                    CreateProcessW(
                        nil,
                        UnsafeMutablePointer(mutating: line),
                        nil,
                        nil,
                        true,
                        DWORD(CREATE_NO_WINDOW) | DWORD(CREATE_UNICODE_ENVIRONMENT),
                        UnsafeMutableRawPointer(mutating: environment),
                        directory,
                        &startup,
                        &spawned
                    )
                }
            }
        }
        guard created else {
            throw ChildProcessError.spawnFailed(reason: "CreateProcessW answered \(GetLastError())")
        }

        CloseHandle(spawned.hThread)
        processIdentifier = Int32(bitPattern: spawned.dwProcessId)
        state.withLock { process = spawned.hProcess }

        handOver(standardInput, writing: false)
        handOver(standardOutput, writing: true)
        handOver(standardError, writing: true)

        watchForExit()
    }

    public func waitUntilExit() {
        guard let process = liveProcess else { return }
        WaitForSingleObject(process, INFINITE)
        readExitCode(of: process)
    }

    public func terminate() {
        guard let process = liveProcess else { return }
        TerminateProcess(process, UINT(1))
    }

    private func watchForExit() {
        let watcher = Thread { [self] in
            guard let process = liveProcess else { return }
            WaitForSingleObject(process, INFINITE)
            readExitCode(of: process)
            terminationHandler?(self)
        }
        watcher.name = "ChildProcess \(processIdentifier)"
        watcher.start()
    }

    private func readExitCode(of process: HANDLE) {
        var code: DWORD = 0
        GetExitCodeProcess(process, &code)
        state.withLock { exitCode = code }
    }

    private var liveProcess: HANDLE? {
        state.withLock { process }
    }

    private func inherited(_ stream: Any?, writing: Bool, opened: inout [HANDLE]) throws -> HANDLE? {
        guard let stream else {
            let device = try Self.nullDevice(writing: writing)
            opened.append(device)
            return device
        }

        let end: FileHandle
        switch stream {
        case let pipe as Pipe:
            end = writing ? pipe.fileHandleForWriting : pipe.fileHandleForReading
        case let handle as FileHandle:
            end = handle
        default:
            throw ChildProcessError.spawnFailed(reason: "a stream was neither a pipe nor a file handle")
        }

        SetHandleInformation(end._handle, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT))
        return end._handle
    }

    private func handOver(_ stream: Any?, writing: Bool) {
        guard let pipe = stream as? Pipe else { return }
        try? (writing ? pipe.fileHandleForWriting : pipe.fileHandleForReading).close()
    }

    private static func nullDevice(writing: Bool) throws -> HANDLE {
        var inheritable = SECURITY_ATTRIBUTES()
        inheritable.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        inheritable.bInheritHandle = true

        let device = "NUL".withCString(encodedAs: UTF16.self) { name in
            CreateFileW(
                name,
                writing ? DWORD(GENERIC_WRITE) : DWORD(GENERIC_READ),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                &inheritable,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_ATTRIBUTE_NORMAL),
                nil
            )
        }
        guard let device, device != INVALID_HANDLE_VALUE else {
            throw ChildProcessError.spawnFailed(reason: "NUL could not be opened")
        }
        return device
    }

    private static func environmentBlock(_ environment: [String: String]) -> String {
        environment.sorted { $0.key.caseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)\0" }.joined()
    }

    private static func quoted(_ commandLine: [String]) -> String {
        commandLine.map(quoted).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        guard argument.contains(where: { " \t\n\"".contains($0) }) else { return argument }

        var quoted = "\""
        var rest = argument.unicodeScalars
        while !rest.isEmpty {
            guard let firstNonBackslash = rest.firstIndex(where: { $0 != "\\" }) else {
                quoted.append(String(repeating: "\\", count: rest.count * 2))
                break
            }
            let backslashes = rest.distance(from: rest.startIndex, to: firstNonBackslash)
            if rest[firstNonBackslash] == "\"" {
                quoted.append(String(repeating: "\\", count: backslashes * 2 + 1))
            } else {
                quoted.append(String(repeating: "\\", count: backslashes))
            }
            quoted.append(String(rest[firstNonBackslash]))
            rest.removeFirst(backslashes + 1)
        }
        quoted.append("\"")
        return quoted
    }
}

public enum ChildProcessError: Swift.Error, LocalizedError {
    case spawnFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let reason):
            return "Unable to start the process: \(reason)"
        }
    }
}

#else

public typealias ChildProcess = Process

#endif
