import Foundation
import Frida

final class QemuMonitor: @unchecked Sendable {
    private let socket: GLib.Socket
    private let queue = DispatchQueue(label: "re.frida.luma.qemu-monitor")
    private var pending = Data()

    init(socketPath: URL, deadline: Date) async throws {
        socket = try await Self.connect(to: socketPath, deadline: deadline)
        try await handshake()
    }

    func execute(_ command: String, arguments: [String: QmpArgument] = [:], passing fileDescriptor: Int32? = nil) async throws -> QmpReply {
        let request = Self.encode(command: command, arguments: arguments)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.exchange(request, passing: fileDescriptor) })
            }
        }
    }

    func peripherals() async throws -> [String] {
        try await names(of: "qom-list", arguments: ["path": .string("/machine/peripheral")], field: "name")
    }

    func chardevs() async throws -> [String] {
        try await names(of: "query-chardev", field: "label")
    }

    func monitor(_ commandLine: String) async throws -> String {
        let reply = try await execute("human-monitor-command", arguments: ["command-line": .string(commandLine)])
        return (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func disconnect() {
        queue.async {
            self.socket.close()
        }
    }

    private func names(of command: String, arguments: [String: QmpArgument] = [:], field: String) async throws -> [String] {
        let request = Self.encode(command: command, arguments: arguments)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.send(request, passing: nil)
                    let entries = try self.readReply()["return"] as? [[String: Any]] ?? []
                    return entries.compactMap { $0[field] as? String }
                })
            }
        }
    }

    private func handshake() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            queue.async {
                continuation.resume(with: Result {
                    _ = try self.readReply()
                    _ = try self.exchange(Self.encode(command: "qmp_capabilities", arguments: [:]), passing: nil)
                })
            }
        }
    }

    private func exchange(_ request: String, passing fileDescriptor: Int32?) throws -> QmpReply {
        try send(request, passing: fileDescriptor)
        return QmpReply(text: try readReply()["return"] as? String)
    }

    private func send(_ request: String, passing fileDescriptor: Int32?) throws {
        try socket.send(Array(request.utf8), fileDescriptors: fileDescriptor.map { [$0] } ?? [])
    }

    private func readReply() throws -> [String: Any] {
        while true {
            let line = try readLine()
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw QmpError.malformedReply
            }
            if let error = object["error"] as? [String: Any] {
                throw QmpError.commandFailed(reason: (error["desc"] as? String) ?? "unknown error")
            }
            if object["event"] != nil {
                continue
            }
            return object
        }
    }

    private func readLine() throws -> String {
        while true {
            if let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<end]
                pending = pending[pending.index(after: end)...]
                return String(decoding: line, as: UTF8.self)
            }

            let chunk = try socket.receive(upTo: 4096)
            guard !chunk.isEmpty else {
                throw QmpError.monitorClosed
            }
            pending.append(contentsOf: chunk)
        }
    }

    private static func encode(command: String, arguments: [String: QmpArgument]) -> String {
        var request = "{\"execute\":\(QmpArgument.string(command).json)"
        if !arguments.isEmpty {
            let fields = arguments.map { "\(QmpArgument.string($0.key).json):\($0.value.json)" }
            request += ",\"arguments\":{\(fields.joined(separator: ","))}"
        }
        return request + "}\n"
    }

    private static func connect(to socketPath: URL, deadline: Date) async throws -> GLib.Socket {
        while true {
            do {
                return try GLib.Socket.connect(unixPath: socketPath.path)
            } catch {
                guard Date() < deadline else {
                    throw QmpError.monitorUnavailable
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

struct QmpReply: Sendable {
    let text: String?
}

enum QmpArgument: Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    var json: String {
        switch self {
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .int(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        }
    }
}

enum QmpError: Swift.Error, LocalizedError {
    case monitorUnavailable
    case monitorClosed
    case malformedReply
    case commandFailed(reason: String)

    var isBusy: Bool {
        guard case .commandFailed(let reason) = self else { return false }
        return reason.contains("busy")
    }

    var errorDescription: String? {
        switch self {
        case .monitorUnavailable:
            return "The machine never opened its monitor"
        case .monitorClosed:
            return "The machine closed its monitor"
        case .malformedReply:
            return "The machine's monitor said something unintelligible"
        case .commandFailed(let reason):
            return reason
        }
    }
}

