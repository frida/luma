import Foundation
import SwiftyR2

public enum Appearance: Sendable, Hashable {
    case light
    case dark
}

public struct DisassemblyRequest: Sendable, Hashable {
    public let address: UInt64
    public let count: Int
    public let appearance: Appearance

    public init(address: UInt64, count: Int, appearance: Appearance) {
        self.address = address
        self.count = count
        self.appearance = appearance
    }
}

public enum DisassemblyScope: Sendable {
    case span
    case function
}

public struct DisassemblyPage: Sendable {
    public let lines: [DisassemblyLine]
    public let scope: DisassemblyScope

    public init(lines: [DisassemblyLine], scope: DisassemblyScope) {
        self.lines = lines
        self.scope = scope
    }
}

@MainActor
public protocol ModuleIntrospector: AnyObject {
    var isAvailable: Bool { get }
    func getModuleIdentity(name: String) async throws -> String?
    func enumerateModuleRanges(name: String) async throws -> [ProcessNode.ModuleRange]
    func enumerateModuleSymbols(name: String) async throws -> ModuleSymbolBundle
}

@MainActor
public protocol MemoryReader: AnyObject {
    func read(at address: UInt64, count: Int) async throws -> [UInt8]
}

@MainActor
public final class Disassembler {
    private let sessionID: UUID
    private let processInfo: ProcessSession.ProcessInfo
    private let store: ProjectStore
    private let modulesProvider: () -> [ProcessModule]
    private let introspector: ModuleIntrospector
    private let reader: MemoryReader

    public var onAnalysisSaved: ((ModuleAnalysis) -> Void)?

    private var r2: R2Core!
    private var openTask: Task<Void, Never>?
    private var currentAppearance: Appearance?
    private var analyzedModules: Set<String> = []

    public init(
        sessionID: UUID,
        processInfo: ProcessSession.ProcessInfo,
        store: ProjectStore,
        modulesProvider: @escaping () -> [ProcessModule],
        introspector: ModuleIntrospector,
        reader: MemoryReader
    ) {
        self.sessionID = sessionID
        self.processInfo = processInfo
        self.store = store
        self.modulesProvider = modulesProvider
        self.introspector = introspector
        self.reader = reader
    }

    public func forgetModule(path: String) {
        analyzedModules.remove(path)
    }

    public func disassemble(_ request: DisassemblyRequest) async -> [DisassemblyLine] {
        await disassemblePage(request).lines
    }

    public func disassemblePage(_ request: DisassemblyRequest) async -> DisassemblyPage {
        await ensureOpened()
        if currentAppearance != request.appearance {
            await r2.applyTheme(Self.r2ThemeName(for: request.appearance))
            currentAppearance = request.appearance
        }
        let hex = String(request.address, radix: 16)
        if let module = moduleContaining(address: request.address) {
            await ensureModuleAnalyzed(module: module)
        }
        if let bounded = await disassembleFunctionIfStart(at: request.address, hex: hex) {
            return DisassemblyPage(lines: bounded, scope: .function)
        }
        let out = await r2.cmd("pdJ \(request.count) @ 0x\(hex)").output ?? ""
        return DisassemblyPage(lines: decodeOps(out), scope: .span)
    }

    private func disassembleFunctionIfStart(at address: UInt64, hex: String) async -> [DisassemblyLine]? {
        guard let begin = await fetchFunctionBegin(hex: hex), begin == address,
            let end = await fetchFunctionEnd(hex: hex), end > begin
        else { return nil }
        let bytes = end &- begin
        let out = await r2.cmd("pDJ \(bytes) @ 0x\(hex)").output ?? ""
        guard let ops = try? JSONDecoder().decode([R2DisasmOp].self, from: Data(out.utf8)) else {
            return nil
        }
        let lines = ops
            .filter { $0.isInstructionEntry }
            .map { $0.toDisassemblyLine() }
            .filter { $0.address < end }
        return lines.isEmpty ? nil : lines
    }

private func fetchFunctionEnd(hex: String) async -> UInt64? {
        let result = await r2.cmd("?v $FE @ 0x\(hex)")
        if result.hasErrors { return nil }
        let raw = (result.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = parseHex(raw), value != 0 else { return nil }
        return value
    }

    private func decodeOps(_ raw: String) -> [DisassemblyLine] {
        guard let ops = try? JSONDecoder().decode([R2DisasmOp].self, from: Data(raw.utf8)) else {
            return []
        }
        return ops.filter { $0.isInstructionEntry }.map { $0.toDisassemblyLine() }
    }

    public func runCommand(_ command: String) async -> R2CommandResult {
        await ensureOpened()
        return await r2.cmd(command)
    }

    public func findFunctionStart(containing address: UInt64) async -> UInt64? {
        await ensureOpened()
        if let module = moduleContaining(address: address) {
            await ensureModuleAnalyzed(module: module)
        }
        return await fetchFunctionBegin(hex: String(address, radix: 16))
    }

    public func findFunctionEnd(containing address: UInt64) async -> UInt64? {
        await ensureOpened()
        if let module = moduleContaining(address: address) {
            await ensureModuleAnalyzed(module: module)
        }
        return await fetchFunctionEnd(hex: String(address, radix: 16))
    }

    public func warmUp(modules: [ProcessModule]) async {
        await ensureOpened()
        for module in modules {
            await ensureModuleAnalyzed(module: module)
        }
    }

    public func applyInsightName(at address: UInt64, title: String) async {
        await ensureOpened()
        if let module = moduleContaining(address: address) {
            await ensureModuleAnalyzed(module: module)
        }
        let hex = String(address, radix: 16)
        let flag = "insight." + r2FlagSafe(title)
        _ = await r2.cmd("f \(flag) @ 0x\(hex)")
        if await fetchFunctionBegin(hex: hex) == address {
            _ = await r2.cmd("afn \(r2FlagSafe(title)) @ 0x\(hex)")
        }
    }

    private func moduleContaining(address: UInt64) -> ProcessModule? {
        modulesProvider().first { address >= $0.base && address < ($0.base &+ $0.size) }
    }

    private func ensureModuleAnalyzed(module: ProcessModule) async {
        if analyzedModules.contains(module.path) { return }

        let identity = try? await introspector.getModuleIdentity(name: module.path)

        if let existing = try? store.fetchModuleAnalysis(sessionID: sessionID, modulePath: module.path),
            canReuse(existing, currentIdentity: identity),
            !existing.functions.isEmpty
        {
            let blocksMissing = existing.functions.allSatisfy { $0.blocks.isEmpty }
            if !(blocksMissing && introspector.isAvailable) {
                analyzedModules.insert(module.path)
                await replayAnalysis(existing, module: module)
                return
            }
        }

        guard introspector.isAvailable else { return }
        analyzedModules.insert(module.path)

        let ranges = (try? await introspector.enumerateModuleRanges(name: module.path)) ?? []
        let stub = ModuleAnalysis(
            sessionID: sessionID,
            modulePath: module.path,
            moduleUUID: identity,
            mappedRanges: ranges,
            functions: []
        )
        try? store.save(stub)

        let bundle = try? await introspector.enumerateModuleSymbols(name: module.path)
        var functions = await registerKnownFunctions(bundle: bundle, module: module)
        await runBoundedPreludeScan(ranges: ranges, module: module)
        await harvestPreludeFunctions(module: module, into: &functions)
        await harvestBasicBlocks(module: module, into: &functions)

        let analysis = ModuleAnalysis(
            sessionID: sessionID,
            modulePath: module.path,
            moduleUUID: identity,
            mappedRanges: ranges,
            functions: functions
        )
        try? store.save(analysis)
        onAnalysisSaved?(analysis)

        await applyUserInsightNames(inModule: module)
    }

    public var insightDisplayTitle: ((AddressInsight) -> String)?

    private func applyUserInsightNames(inModule module: ProcessModule) async {
        guard let title = insightDisplayTitle else { return }
        let lo = module.base
        let hi = module.base &+ module.size
        let insights = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        for insight in insights where insight.parentInsightID == nil {
            guard let address = insight.lastResolvedAddress, address >= lo, address < hi else { continue }
            await applyInsightName(at: address, title: title(insight))
        }
    }

    private func canReuse(_ analysis: ModuleAnalysis, currentIdentity: String?) -> Bool {
        guard let currentIdentity else { return true }
        return analysis.moduleUUID == currentIdentity
    }

    private func replayAnalysis(_ analysis: ModuleAnalysis, module: ProcessModule) async {
        for function in analysis.functions {
            let addr = module.base &+ function.offset
            await defineFunction(at: addr, name: function.name)
        }
    }

    private func registerKnownFunctions(bundle: ModuleSymbolBundle?, module: ProcessModule) async -> [ModuleAnalysis.Function] {
        guard let bundle else { return [] }
        var result: [ModuleAnalysis.Function] = []
        var seenOffsets: Set<UInt64> = []
        let lo = module.base
        let hi = module.base &+ module.size

        for export in bundle.exports where export.kind == .function {
            guard export.address >= lo, export.address < hi else { continue }
            let offset = export.address &- lo
            await defineFunction(at: export.address, name: export.name)
            result.append(.init(offset: offset, name: export.name, source: .exported))
            seenOffsets.insert(offset)
        }
        for symbol in bundle.symbols where symbol.isCode {
            guard symbol.address > lo, symbol.address < hi else { continue }
            let offset = symbol.address &- lo
            if seenOffsets.contains(offset) { continue }
            await defineFunction(at: symbol.address, name: symbol.name)
            result.append(.init(offset: offset, name: symbol.name, source: .symbol))
            seenOffsets.insert(offset)
        }
        return result
    }

    private func runBoundedPreludeScan(ranges: [ProcessNode.ModuleRange], module: ProcessModule) async {
        for range in ranges where range.protection.contains("x") {
            let lo = module.base &+ range.offset
            let hi = lo &+ range.size
            _ = await r2.cmd("e search.from=0x\(String(lo, radix: 16))")
            _ = await r2.cmd("e search.to=0x\(String(hi, radix: 16))")
            _ = await r2.cmd("aap")
        }
    }

    private func harvestPreludeFunctions(module: ProcessModule, into functions: inout [ModuleAnalysis.Function]) async {
        let raw = await r2.cmd("aflj").output ?? ""
        guard let entries = try? JSONDecoder().decode([R2FunctionEntry].self, from: Data(raw.utf8)) else { return }
        let lo = module.base
        let hi = module.base &+ module.size
        var seen = Set(functions.map(\.offset))
        for entry in entries {
            let absolute = entry.offset.value
            guard absolute >= lo, absolute < hi else { continue }
            let offset = absolute &- lo
            if seen.contains(offset) { continue }
            seen.insert(offset)
            functions.append(.init(offset: offset, name: nil, source: .prelude))
        }
    }

    private func harvestBasicBlocks(module: ProcessModule, into functions: inout [ModuleAnalysis.Function]) async {
        for index in functions.indices {
            let entry = module.base &+ functions[index].offset
            let raw = await r2.cmd("afbj @ 0x\(String(entry, radix: 16))").output ?? ""
            guard let entries = try? JSONDecoder().decode([R2BasicBlockEntry].self, from: Data(raw.utf8)) else { continue }
            functions[index].blocks = entries
                .compactMap { block -> ModuleAnalysis.Function.Block? in
                    guard block.addr.value >= module.base else { return nil }
                    return .init(offset: block.addr.value &- module.base, size: block.size.value)
                }
                .sorted { $0.offset < $1.offset }
        }
    }

    private func defineFunction(at address: UInt64, name: String?) async {
        guard address != 0 else { return }
        let hex = String(address, radix: 16)
        let flag = (name?.isEmpty == false) ? r2FlagSafe(name!) : "fcn.\(hex)"
        _ = await r2.cmd("af \(flag) 0x\(hex)")
    }

    private func r2FlagSafe(_ name: String) -> String {
        name.map { c -> Character in
            if c.isLetter || c.isNumber || c == "_" || c == "." { return c }
            return "_"
        }.reduce(into: "") { $0.append($1) }
    }

    private func fetchFunctionBegin(hex: String) async -> UInt64? {
        let result = await r2.cmd("?v $FB @ 0x\(hex)")
        if result.hasErrors { return nil }
        let raw = (result.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = parseHex(raw), value != 0 else { return nil }
        return value
    }

    private func parseHex(_ text: String) -> UInt64? {
        let lower = text.lowercased()
        if lower.hasPrefix("0x") {
            return UInt64(lower.dropFirst(2), radix: 16)
        }
        return UInt64(lower, radix: 16) ?? UInt64(lower)
    }

    public func decompile(at address: UInt64) async -> R2CommandResult {
        await ensureOpened()
        let hex = String(address, radix: 16)
        await r2.cmd("af @ 0x\(hex)")
        return await r2.cmd("pdc @ 0x\(hex)")
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
                asyncProvider: ProcessMemoryIOProvider(reader: reader),
                uriSchemes: ["frida-mem://"]
            )

            await r2.setColorLimit(.mode16M)

            await r2.config.set("log.quiet", bool: true)
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

            await self.applyUserInsightNames()
        }

        openTask = task
        await task.value
    }

    private func applyUserInsightNames() async {
        guard let title = insightDisplayTitle else { return }
        let insights = (try? store.fetchInsights(sessionID: sessionID)) ?? []
        for insight in insights where insight.parentInsightID == nil {
            guard let address = insight.lastResolvedAddress else { continue }
            let hex = String(address, radix: 16)
            let flag = "insight." + r2FlagSafe(title(insight))
            _ = await r2.cmd("f \(flag) @ 0x\(hex)")
        }
    }

    static func r2ThemeName(for appearance: Appearance) -> String {
        switch appearance {
        case .dark: return "default"
        case .light: return "iaito"
        }
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

@MainActor
public protocol PageKeying: AnyObject {
    func attribution(pageBase: UInt64) async -> PageAttribution
    func moduleUUID(forPath path: String) async -> String?
    var processIdentity: String? { get }
}

public enum PageAttribution: Sendable {
    case module(ProcessModule)
    case anonymous
    case ephemeral
}

@MainActor
public final class CachingMemoryReader: MemoryReader {
    private let sessionID: UUID
    private let store: ProjectStore
    private let keying: PageKeying
    public var live: MemoryReader?
    public var publish: ((MemoryPagePublish) -> Void)?
    public var fetchRemote: ((MemoryPageRegion) async -> Data?)?

    private var ephemeralCache: [UInt64: Data] = [:]

    public init(sessionID: UUID, store: ProjectStore, keying: PageKeying, live: MemoryReader?) {
        self.sessionID = sessionID
        self.store = store
        self.keying = keying
        self.live = live
    }

    public func read(at address: UInt64, count: Int) async throws -> [UInt8] {
        let end = address &+ UInt64(count)
        var output: [UInt8] = []
        output.reserveCapacity(count)

        var cursor = address
        while cursor < end {
            let page = try await pageContaining(address: cursor)
            let pageEnd = page.base &+ UInt64(page.bytes.count)
            let copyEnd = min(end, pageEnd)
            let offsetInPage = Int(cursor &- page.base)
            let copyCount = Int(copyEnd &- cursor)
            let slice = page.bytes.subdata(in: offsetInPage..<(offsetInPage + copyCount))
            output.append(contentsOf: slice)
            cursor = copyEnd
        }
        return output
    }

    private func pageContaining(address: UInt64) async throws -> ResolvedPage {
        let key = await pageKey(for: address)
        if let bytes = cachedBytes(for: key) {
            return ResolvedPage(base: key.pageBase, bytes: bytes)
        }
        if let remote = try await fetchRemoteBytes(for: key) {
            persist(key, bytes: remote, publishToRoom: false)
            return ResolvedPage(base: key.pageBase, bytes: remote)
        }
        guard let live else {
            throw DisassemblyError.notCached(pageAddress: key.pageBase)
        }
        let raw = try await live.read(at: key.pageBase, count: Int(MemoryPage.size))
        let bytes = Data(raw)
        persist(key, bytes: bytes, publishToRoom: true)
        return ResolvedPage(base: key.pageBase, bytes: bytes)
    }

    private func ephemeralBytes(at pageBase: UInt64) -> Data? {
        ephemeralCache[pageBase]
    }

    private func fetchRemoteBytes(for key: PageKey) async throws -> Data? {
        guard let fetchRemote, case .mapped(let region) = key.region else { return nil }
        return await fetchRemote(region)
    }

    private func pageKey(for address: UInt64) async -> PageKey {
        let base = MemoryPage.base(of: address)
        switch await keying.attribution(pageBase: base) {
        case .module(let module):
            guard let uuid = await keying.moduleUUID(forPath: module.path) else {
                return PageKey(pageBase: base, region: .ephemeral)
            }
            return PageKey(pageBase: base, region: .mapped(.module(uuid: uuid, offset: base &- module.base)))
        case .anonymous:
            guard let identity = keying.processIdentity else {
                return PageKey(pageBase: base, region: .ephemeral)
            }
            return PageKey(pageBase: base, region: .mapped(.anonymous(identity: identity, address: base)))
        case .ephemeral:
            return PageKey(pageBase: base, region: .ephemeral)
        }
    }

    private func cachedBytes(for key: PageKey) -> Data? {
        guard case .mapped(let region) = key.region else {
            return ephemeralBytes(at: key.pageBase)
        }
        switch region {
        case .module(let uuid, let offset):
            return (try? store.fetchMemoryPage(sessionID: sessionID, moduleUUID: uuid, offset: offset))?.bytes
        case .anonymous(let identity, let address):
            return (try? store.fetchMemoryPage(sessionID: sessionID, processIdentity: identity, address: address))?.bytes
        }
    }

    private func persist(_ key: PageKey, bytes: Data, publishToRoom: Bool) {
        guard case .mapped(let region) = key.region else {
            ephemeralCache[key.pageBase] = bytes
            return
        }
        switch region {
        case .module(let uuid, let offset):
            try? store.save(MemoryPageModule(sessionID: sessionID, moduleUUID: uuid, offset: offset, bytes: bytes))
        case .anonymous(let identity, let address):
            try? store.save(MemoryPageAnon(sessionID: sessionID, processIdentity: identity, address: address, bytes: bytes))
        }
        if publishToRoom {
            publish?(MemoryPagePublish(region: region, bytes: bytes))
        }
    }

    private struct PageKey {
        let pageBase: UInt64
        let region: Region

        enum Region {
            case mapped(MemoryPageRegion)
            case ephemeral
        }
    }

    private struct ResolvedPage {
        let base: UInt64
        let bytes: Data
    }
}

public enum DisassemblyError: Error, LocalizedError {
    case notCached(pageAddress: UInt64)
    case detached

    public var errorDescription: String? {
        switch self {
        case .notCached(let page):
            return "No cached memory at 0x\(String(page, radix: 16)). Reattach to fetch it."
        case .detached:
            return "Operation requires a live session."
        }
    }
}

private final class ProcessMemoryIOProvider: R2IOAsyncProvider, @unchecked Sendable {
    unowned let reader: MemoryReader

    init(reader: MemoryReader) {
        self.reader = reader
    }

    func supports(path: String, many: Bool) -> Bool {
        path.hasPrefix("frida-mem://")
    }

    func open(path: String, access: R2IOAccess, mode: Int32) async throws -> R2IOAsyncFile {
        guard let req = FridaMemURI.parse(path) else {
            throw NSError(domain: "LumaCore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid frida-mem URI"])
        }
        return ProcessMemoryIOFile(reader: reader, baseAddress: req.baseAddress)
    }
}

private final class ProcessMemoryIOFile: R2IOAsyncFile, @unchecked Sendable {
    private unowned let reader: MemoryReader
    private let baseAddress: UInt64

    init(reader: MemoryReader, baseAddress: UInt64) {
        self.reader = reader
        self.baseAddress = baseAddress
    }

    func close() async throws {}

    func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
        try await reader.read(at: baseAddress &+ offset, count: count)
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

private struct R2Hex: Decodable {
    let value: UInt64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            let trimmed = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
            guard let parsed = UInt64(trimmed, radix: 16) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid hex: \(text)")
            }
            value = parsed
            return
        }
        value = try container.decode(UInt64.self)
    }
}

private struct R2FunctionEntry: Decodable {
    let offset: R2Hex
}

private struct R2BasicBlockEntry: Decodable {
    let addr: R2Hex
    let size: R2Hex
}

private struct R2DisasmOp: Decodable {
    let addr: String
    let text: String
    let arrow: String?
    let call: String?

    var addrValue: UInt64 { UInt64(addr.dropFirst(2), radix: 16) ?? 0 }
    var arrowValue: UInt64? { arrow.flatMap { UInt64($0.dropFirst(2), radix: 16) } }
    var callValue: UInt64? { call.flatMap { UInt64($0.dropFirst(2), radix: 16) } }

    var isInstructionEntry: Bool {
        StyledText.parseAnsi(text).plainText.contains(addr)
    }

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
