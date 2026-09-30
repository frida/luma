import Foundation
import SwiftyR2

extension PatternVisualization.Disassembly {
    public struct Instruction: Identifiable, Sendable {
        public var id: UInt64 { address }
        public let address: UInt64
        public let bytes: String
        public let text: String
    }

    public func instructions() async throws -> [Instruction] {
        guard let target = R2Target(architecture: architecture) else {
            throw PatternVisualizationError("Unknown architecture \"\(architecture)\".")
        }
        let r2 = await R2Core.create()
        await r2.config.set("log.quiet", bool: true)
        await r2.config.set("asm.arch", string: target.arch)
        await r2.config.set("asm.bits", int: target.bits)
        await r2.config.set("cfg.bigendian", bool: target.isBigEndian)
        let origin = "0x" + String(address, radix: 16)
        await r2.cmd("o malloc://\(data.count) \(origin)")
        await r2.cmd("wx \(data.map { String(format: "%02x", $0) }.joined()) @ \(origin)")
        let listing = await r2.cmd("pDj \(data.count) @ \(origin)").output ?? "[]"
        return try JSONDecoder().decode([R2Instruction].self, from: Data(listing.utf8)).map {
            Instruction(address: $0.addr, bytes: $0.bytes.hexPairs, text: $0.disasm)
        }
    }
}

private struct R2Instruction: Decodable {
    let addr: UInt64
    let bytes: String
    let disasm: String
}

private struct R2Target {
    let arch: String
    let bits: Int
    let isBigEndian: Bool

    init?(architecture: String) {
        let parts = architecture.split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var name = parts.first ?? ""
        let options = Set((parts.count > 1 ? parts[1] : "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))

        isBigEndian = name.hasSuffix("be") || name.hasSuffix("eb")
        if isBigEndian || name.hasSuffix("le") || name.hasSuffix("el") {
            name.removeLast(2)
        }

        guard let (arch, defaultBits) = Self.known[name] else { return nil }
        self.arch = arch
        if options.contains("thumb") {
            bits = 16
        } else if let explicit = [16, 32, 64].first(where: { options.contains("\($0)bit") }) {
            bits = explicit
        } else {
            bits = defaultBits
        }
    }

    private static let known: [String: (String, Int)] = [
        "arm": ("arm", 32),
        "thumb": ("arm", 16),
        "aarch64": ("arm", 64),
        "arm64": ("arm", 64),
        "mips": ("mips", 32),
        "x86": ("x86", 32),
        "x86_64": ("x86", 64),
        "x64": ("x86", 64),
        "ppc": ("ppc", 32),
        "powerpc": ("ppc", 32),
        "sparc": ("sparc", 32),
        "sysz": ("sysz", 64),
        "xcore": ("xcore", 32),
        "m68k": ("m68k", 32),
        "m680x": ("m680x", 8),
        "tms320c64x": ("tms320", 32),
        "evm": ("evm", 8),
        "wasm": ("wasm", 32),
        "riscv": ("riscv", 32),
        "mos65xx": ("6502", 8),
        "bpf": ("bpf", 64),
        "sh": ("sh", 32),
        "superh": ("sh", 32),
        "tricore": ("tricore", 32),
    ]
}

extension String {
    fileprivate var hexPairs: String {
        let digits = Array(uppercased())
        return stride(from: 0, to: digits.count, by: 2).map { String(digits[$0..<min($0 + 2, digits.count)]) }.joined(separator: " ")
    }
}
