import Foundation
import SwiftyR2

@MainActor
public final class TraceDisassembler {
    private let decoded: DecodedITrace
    private let processInfo: ProcessSession.ProcessInfo
    private weak var liveNode: ProcessNode?

    private var r2: R2Core!
    private var openTask: Task<Void, Never>?
    private var currentDarkMode: Bool?

    public init(
        decoded: DecodedITrace,
        processInfo: ProcessSession.ProcessInfo,
        liveNode: ProcessNode?
    ) {
        self.decoded = decoded
        self.processInfo = processInfo
        self.liveNode = liveNode
    }

    public func disassemble(at address: UInt64, size: Int, isDarkMode: Bool, withFlags: Bool = true) async -> StyledText {
        await ensureOpened()
        if currentDarkMode != isDarkMode {
            await r2.applyTheme(isDarkMode ? "default" : "iaito")
            currentDarkMode = isDarkMode
        }
        if !withFlags {
            await r2.config.set("asm.flags", bool: false)
        }
        var raw = await r2.cmd("pD \(size) @ 0x\(String(address, radix: 16))")
        if !withFlags {
            await r2.config.set("asm.flags", bool: true)
        }
        while raw.hasSuffix("\n") { raw.removeLast() }
        return StyledText.parseAnsi(raw)
    }

    private func ensureOpened() async {
        if let openTask {
            await openTask.value
            return
        }

        let task = Task { @MainActor in
            let r2 = await R2Core.create()
            self.r2 = r2

            let provider = TraceIOProvider(blockBytes: decoded.blockBytes, liveNode: liveNode)
            await r2.registerIOPlugin(asyncProvider: provider, uriSchemes: ["itrace://"])

            await r2.setColorLimit(.mode16M)

            await r2.config.set("scr.utf8", bool: true)
            await r2.config.set("scr.color", colorMode: .mode16M)
            await r2.config.set("cfg.json.num", string: "hex")
            await r2.config.set("asm.lines", bool: false)
            await r2.config.set("asm.emu", bool: true)
            await r2.config.set("emu.str", bool: true)
            await r2.config.set("anal.cc", string: "cdecl")

            await r2.config.set("asm.os", string: processInfo.platform)
            await r2.config.set("asm.arch", string: Disassembler.r2Arch(fromFridaArch: processInfo.arch))
            await r2.config.set("asm.bits", int: processInfo.pointerSize * 8)

            let uri = "itrace://0x0"
            await r2.openFile(uri: uri)
            await r2.cmd("=!")
            await r2.binLoad(uri: uri)

            await registerFlags()
        }

        openTask = task
        await task.value
    }

    private func registerFlags() async {
        var seen = Set<UInt64>()
        var usedNames = Set<String>()

        for entry in decoded.entries {
            guard seen.insert(entry.blockAddress).inserted else { continue }
            guard let bangIdx = entry.blockName.firstIndex(of: "!") else { continue }

            var symbol = String(entry.blockName[entry.blockName.index(after: bangIdx)...])
            symbol = symbol.replacingOccurrences(of: "0x", with: "")
            var name = sanitizeFlagName(symbol)
            guard !name.isEmpty else { continue }

            if usedNames.contains(name) {
                var i = 2
                while usedNames.contains("\(name)_\(i)") { i += 1 }
                name = "\(name)_\(i)"
            }
            usedNames.insert(name)

            _ = await r2.cmd("f \(name) @ 0x\(String(entry.blockAddress, radix: 16))")
        }
    }

    private func sanitizeFlagName(_ name: String) -> String {
        var result = ""
        for ch in name {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." {
                result.append(ch)
            } else {
                result.append("_")
            }
        }
        return result
    }
}

private final class TraceIOProvider: R2IOAsyncProvider, @unchecked Sendable {
    private let blockBytes: [UInt64: Data]
    private weak var liveNode: ProcessNode?

    init(blockBytes: [UInt64: Data], liveNode: ProcessNode?) {
        self.blockBytes = blockBytes
        self.liveNode = liveNode
    }

    func supports(path: String, many: Bool) -> Bool {
        path.hasPrefix("itrace://")
    }

    func open(path: String, access: R2IOAccess, mode: Int32) async throws -> R2IOAsyncFile {
        TraceIOFile(blockBytes: blockBytes, liveNode: liveNode)
    }
}

private final class TraceIOFile: R2IOAsyncFile, @unchecked Sendable {
    private let blockBytes: [UInt64: Data]
    private weak var liveNode: ProcessNode?

    init(blockBytes: [UInt64: Data], liveNode: ProcessNode?) {
        self.blockBytes = blockBytes
        self.liveNode = liveNode
    }

    func close() async throws {}

    func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        let reqStart = offset
        let reqEnd = offset + UInt64(count)

        for (blockAddr, data) in blockBytes {
            let blockEnd = blockAddr + UInt64(data.count)
            guard reqStart < blockEnd, reqEnd > blockAddr else { continue }

            var result = [UInt8](repeating: 0, count: count)

            let overlapStart = max(reqStart, blockAddr)
            let overlapEnd = min(reqEnd, blockEnd)
            let srcOffset = Int(overlapStart - blockAddr)
            let dstOffset = Int(overlapStart - reqStart)
            let overlapLen = Int(overlapEnd - overlapStart)
            data.copyBytes(
                to: &result[dstOffset],
                from: srcOffset..<(srcOffset + overlapLen)
            )

            if reqStart < blockAddr {
                let prefixLen = Int(blockAddr - reqStart)
                if let liveBytes = try? await readLive(at: reqStart, count: prefixLen) {
                    result.replaceSubrange(0..<prefixLen, with: liveBytes.prefix(prefixLen))
                }
            }

            if reqEnd > blockEnd {
                let suffixStart = blockEnd
                let suffixLen = Int(reqEnd - blockEnd)
                let dstStart = Int(suffixStart - reqStart)
                if let liveBytes = try? await readLive(at: suffixStart, count: suffixLen) {
                    result.replaceSubrange(dstStart..<(dstStart + suffixLen), with: liveBytes.prefix(suffixLen))
                }
            }

            return result
        }

        if let liveBytes = try? await readLive(at: offset, count: count) {
            return liveBytes
        }

        return [UInt8](repeating: 0, count: count)
    }

    private func readLive(at address: UInt64, count: Int) async throws -> [UInt8] {
        guard let liveNode else {
            throw NSError(domain: "LumaCore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Process not available"])
        }
        return try await liveNode.readRemoteMemory(at: address, count: count)
    }

    func write(at offset: UInt64, bytes: [UInt8]) async throws -> Int { 0 }
    func size() async throws -> UInt64 { UInt64.max }
    func setSize(_ size: UInt64) async throws {}
}
