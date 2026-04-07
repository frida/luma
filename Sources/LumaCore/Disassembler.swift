import Foundation
import SwiftyR2

public struct DisassemblyRequest: Sendable, Hashable {
    public let address: UInt64
    public let count: Int
    public let isDarkMode: Bool

    public init(address: UInt64, count: Int, isDarkMode: Bool) {
        self.address = address
        self.count = count
        self.isDarkMode = isDarkMode
    }
}

@MainActor
public final class Disassembler {
    private let node: ProcessNode
    private let processInfo: ProcessSession.ProcessInfo

    private var r2: R2Core!
    private var openTask: Task<Void, Never>?
    private var currentDarkMode: Bool?

    public init(node: ProcessNode, processInfo: ProcessSession.ProcessInfo) {
        self.node = node
        self.processInfo = processInfo
    }

    public func disassemble(_ request: DisassemblyRequest) async -> [DisassemblyLine] {
        await ensureOpened()
        if currentDarkMode != request.isDarkMode {
            await r2.applyTheme(request.isDarkMode ? "default" : "iaito")
            currentDarkMode = request.isDarkMode
        }
        let out = await r2.cmd("pdJ \(request.count) @ 0x\(String(request.address, radix: 16))")
        guard let ops = try? JSONDecoder().decode([R2DisasmOp].self, from: Data(out.utf8)) else {
            return []
        }
        return ops.map { $0.toDisassemblyLine() }
    }

    private func ensureOpened() async {
        if let openTask {
            await openTask.value
            return
        }

        let task = Task { @MainActor in
            let r2 = await R2Core.create()
            self.r2 = r2

            await r2.registerIOPlugin(
                asyncProvider: ProcessMemoryIOProvider(node: node),
                uriSchemes: ["frida-mem://"]
            )

            await r2.setColorLimit(.mode16M)

            await r2.config.set("scr.utf8", bool: true)
            await r2.config.set("scr.color", colorMode: .mode16M)
            await r2.config.set("cfg.json.num", string: "hex")
            await r2.config.set("asm.emu", bool: true)
            await r2.config.set("emu.str", bool: true)
            await r2.config.set("anal.cc", string: "cdecl")

            await r2.config.set("asm.os", string: processInfo.platform)
            await r2.config.set("asm.arch", string: Self.r2Arch(fromFridaArch: processInfo.arch))
            await r2.config.set("asm.bits", int: processInfo.pointerSize * 8)

            let uri = "frida-mem://0x0"
            await r2.openFile(uri: uri)
            await r2.cmd("=!")
            await r2.binLoad(uri: uri)
        }

        openTask = task
        await task.value
    }

    public static func r2Arch(fromFridaArch arch: String) -> String {
        switch arch {
        case "ia32", "x64":
            return "x86"
        case "arm64":
            return "arm"
        default:
            return arch
        }
    }
}

private final class ProcessMemoryIOProvider: R2IOAsyncProvider, @unchecked Sendable {
    unowned let node: ProcessNode

    init(node: ProcessNode) {
        self.node = node
    }

    func supports(path: String, many: Bool) -> Bool {
        path.hasPrefix("frida-mem://")
    }

    func open(path: String, access: R2IOAccess, mode: Int32) async throws -> R2IOAsyncFile {
        guard let req = FridaMemURI.parse(path) else {
            throw NSError(domain: "LumaCore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid frida-mem URI"])
        }
        return ProcessMemoryIOFile(node: node, baseAddress: req.baseAddress)
    }
}

private final class ProcessMemoryIOFile: R2IOAsyncFile, @unchecked Sendable {
    private unowned let node: ProcessNode
    private let baseAddress: UInt64

    init(node: ProcessNode, baseAddress: UInt64) {
        self.node = node
        self.baseAddress = baseAddress
    }

    func close() async throws {}

    func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        try await node.readRemoteMemory(at: baseAddress &+ offset, count: count)
    }

    func write(at offset: UInt64, bytes: [UInt8]) async throws -> Int { 0 }
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

private struct R2DisasmOp: Decodable {
    let addr: String
    let text: String
    let arrow: String?
    let call: String?

    var addrValue: UInt64 { UInt64(addr.dropFirst(2), radix: 16) ?? 0 }
    var arrowValue: UInt64? { arrow.flatMap { UInt64($0.dropFirst(2), radix: 16) } }
    var callValue: UInt64? { call.flatMap { UInt64($0.dropFirst(2), radix: 16) } }

    func toDisassemblyLine() -> DisassemblyLine {
        let styled = StyledText.parseAnsi(text)
        let plain = styled.plainText

        let addrR = plain.range(of: addr) ?? plain.startIndex..<plain.startIndex
        let addrStart = plain.distance(from: plain.startIndex, to: addrR.lowerBound)
        let addrEnd = plain.distance(from: plain.startIndex, to: addrR.upperBound)

        let afterAddr = plain[addrR.upperBound...]
        let trimmedAfterAddr = afterAddr.drop(while: { $0 == " " || $0 == "\t" })
        let bytesStartInAfter = afterAddr.distance(from: afterAddr.startIndex, to: trimmedAfterAddr.startIndex)
        let bytesStart = addrEnd + bytesStartInAfter

        let bytesToken = trimmedAfterAddr.prefix { $0 != " " && $0 != "\t" }
        let bytesEnd = bytesStart + bytesToken.count

        var remStart = bytesEnd
        while remStart < plain.count {
            let idx = plain.index(plain.startIndex, offsetBy: remStart)
            if plain[idx] == " " || plain[idx] == "\t" { remStart += 1 } else { break }
        }
        let remainder = String(plain.dropFirst(remStart))

        let asmPlain: String
        let commentPlain: String?
        if let semi = remainder.firstIndex(of: ";") {
            asmPlain = remainder[..<semi].trimmingCharacters(in: .whitespaces)
            commentPlain = remainder[semi...].trimmingCharacters(in: .whitespaces)
        } else {
            asmPlain = remainder.trimmingCharacters(in: .whitespaces)
            commentPlain = nil
        }

        let asmOffsetInRem = remainder.range(of: asmPlain)?.lowerBound ?? remainder.startIndex
        let asmStart = remStart + remainder.distance(from: remainder.startIndex, to: asmOffsetInRem)
        let asmEnd = asmStart + asmPlain.count

        let commentSlice: StyledText?
        if let commentPlain, let cr = remainder.range(of: commentPlain) {
            let cStart = remStart + remainder.distance(from: remainder.startIndex, to: cr.lowerBound)
            let cEnd = cStart + commentPlain.count
            commentSlice = styled.slice(charRange: cStart..<cEnd)
        } else {
            commentSlice = nil
        }

        return DisassemblyLine(
            address: addrValue,
            branchTarget: arrowValue,
            callTarget: callValue,
            addressText: styled.slice(charRange: addrStart..<addrEnd),
            bytesText: styled.slice(charRange: bytesStart..<bytesEnd),
            asmText: styled.slice(charRange: asmStart..<asmEnd),
            commentText: commentSlice
        )
    }
}
