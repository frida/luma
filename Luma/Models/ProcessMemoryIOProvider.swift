import Foundation
import SwiftyR2

final class ProcessMemoryIOProvider: R2IOAsyncProvider, @unchecked Sendable {
    unowned let processNode: ProcessNode

    init(processNode: ProcessNode) {
        self.processNode = processNode
    }

    func supports(path: String, many: Bool) -> Bool {
        path.hasPrefix("frida-mem://")
    }

    func open(path: String, access: R2IOAccess, mode: Int32) async throws -> R2IOAsyncFile {
        guard let req = FridaMemURI.parse(path) else {
            throw NSError(domain: "Luma", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid frida-mem URI"])
        }
        return ProcessMemoryIOFile(processNode: processNode, baseAddress: req.baseAddress)
    }
}

final class ProcessMemoryIOFile: R2IOAsyncFile, @unchecked Sendable {
    private unowned let processNode: ProcessNode
    private let baseAddress: UInt64

    init(processNode: ProcessNode, baseAddress: UInt64) {
        self.processNode = processNode
        self.baseAddress = baseAddress
    }

    func close() async throws {}

    func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        try await processNode.readRemoteMemory(at: baseAddress &+ offset, count: count)
    }

    func write(at offset: UInt64, bytes: [UInt8]) async throws -> Int {
        return 0
    }

    func size() async throws -> UInt64 { UInt64.max }
    func setSize(_ size: UInt64) async throws {}
}

private struct FridaMemURI {
    let baseAddress: UInt64

    nonisolated static func parse(_ uri: String) -> FridaMemURI? {
        guard let url = URL(string: uri), url.scheme == "frida-mem" else { return nil }

        let raw = url.host ?? ""
        guard raw.hasPrefix("0x"), let base = UInt64(raw.dropFirst(2), radix: 16) else { return nil }

        return FridaMemURI(baseAddress: base)
    }
}
