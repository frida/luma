import Foundation
import Frida

@MainActor
public final class PatternDecoder {
    public static let processMemoryDefines: [String: String] = ["__MEMORY__": ""]

    private let compiler = PatternCompiler()
    private let projectRoot: URL
    private let draftDirectory: URL
    private let defines: [String: String]
    private var summaries: [SummaryKey: SourceSummary] = [:]

    public init(projectRoot: URL, draftDirectory: URL, defines: [String: String]) {
        self.projectRoot = projectRoot
        self.draftDirectory = draftDirectory
        self.defines = defines
    }

    public func summary(of source: PatternSource, platform: String? = nil, arch: String? = nil) async throws -> PatternSummary {
        let key = SummaryKey(sourceID: source.id, platform: platform, arch: arch)
        if let cached = summaries[key], cached.text == source.text {
            return cached.summary
        }
        let summary = try await Self.summary(
            of: source.workspacePath, in: projectRoot, platform: platform, arch: arch, defines: defines, using: compiler)
        summaries[key] = SourceSummary(text: source.text, summary: summary)
        return summary
    }

    public func summary(ofText text: String, platform: String? = nil, arch: String? = nil) async throws -> PatternSummary {
        try await Self.withDraft(text, in: draftDirectory, of: projectRoot) { [projectRoot, defines, compiler] entrypoint in
            try await Self.summary(of: entrypoint, in: projectRoot, platform: platform, arch: arch, defines: defines, using: compiler)
        }
    }

    private nonisolated static func summary(
        of entrypoint: String, in projectRoot: URL, platform: String?, arch: String?, defines: [String: String],
        using compiler: PatternCompiler
    ) async throws -> PatternSummary {
        let module = try await compile(entrypoint, in: projectRoot, platform: platform, arch: arch, defines: defines, using: compiler)
        return PatternSummary(module: module, entrypoint: entrypoint)
    }

    public func decode(
        _ source: PatternSource,
        typeName: String,
        data: Data,
        address: UInt64,
        platform: String? = nil,
        arch: String? = nil,
        inputs: [String: PatternInputValue] = [:]
    ) async throws -> DecodedPattern {
        try await Self.decode(
            source.workspacePath, in: projectRoot, typeName: typeName, data: Array(data), address: address, platform: platform,
            arch: arch, defines: defines, inputs: inputs, using: compiler)
    }

    public func decode(
        text: String,
        typeName: String,
        data: Data,
        address: UInt64,
        platform: String? = nil,
        arch: String? = nil,
        inputs: [String: PatternInputValue] = [:]
    ) async throws -> DecodedPattern {
        try await Self.withDraft(text, in: draftDirectory, of: projectRoot) { [projectRoot, defines, compiler] entrypoint in
            try await Self.decode(
                entrypoint, in: projectRoot, typeName: typeName, data: Array(data), address: address, platform: platform, arch: arch,
                defines: defines, inputs: inputs, using: compiler)
        }
    }

    private nonisolated static func decode(
        _ entrypoint: String,
        in projectRoot: URL,
        typeName: String,
        data: [UInt8],
        address: UInt64,
        platform: String?,
        arch: String?,
        defines: [String: String],
        inputs: [String: PatternInputValue],
        using compiler: PatternCompiler
    ) async throws -> DecodedPattern {
        let module = try await compile(entrypoint, in: projectRoot, platform: platform, arch: arch, defines: defines, using: compiler)
        let value = try await module.decode(
            typeName: typeName, data: data, address: address, inputs: inputs.isEmpty ? nil : inputs.mapValues(\.rawValue))
        return DecodedPattern(value: value)
    }

    public func callFunction(
        _ function: String,
        on nodeID: UInt,
        of source: PatternSource,
        typeName: String,
        data: Data,
        address: UInt64,
        platform: String? = nil,
        arch: String? = nil
    ) async throws -> String {
        try await Self.callFunction(
            function, on: nodeID, of: source.workspacePath, in: projectRoot, typeName: typeName, data: Array(data), address: address,
            platform: platform, arch: arch, defines: defines, using: compiler)
    }

    public func callFunction(
        _ function: String,
        on nodeID: UInt,
        ofText text: String,
        typeName: String,
        data: Data,
        address: UInt64,
        platform: String? = nil,
        arch: String? = nil
    ) async throws -> String {
        try await Self.withDraft(text, in: draftDirectory, of: projectRoot) { [projectRoot, defines, compiler] entrypoint in
            try await Self.callFunction(
                function, on: nodeID, of: entrypoint, in: projectRoot, typeName: typeName, data: Array(data), address: address,
                platform: platform, arch: arch, defines: defines, using: compiler)
        }
    }

    private nonisolated static func callFunction(
        _ function: String,
        on nodeID: UInt,
        of entrypoint: String,
        in projectRoot: URL,
        typeName: String,
        data: [UInt8],
        address: UInt64,
        platform: String?,
        arch: String?,
        defines: [String: String],
        using compiler: PatternCompiler
    ) async throws -> String {
        let module = try await compile(entrypoint, in: projectRoot, platform: platform, arch: arch, defines: defines, using: compiler)
        return try await module.callFunction(typeName: typeName, data: data, address: address, pattern: nodeID, function: function)
    }

    private nonisolated static func compile(
        _ entrypoint: String, in projectRoot: URL, platform: String?, arch: String?, defines: [String: String],
        using compiler: PatternCompiler
    ) async throws -> PatternModule {
        try await compiler.compile(
            entrypoint: entrypoint, projectRoot: projectRoot.path, platform: platform, arch: arch, defines: defines)
    }

    // The module goes back to its entrypoint on every decode, so the draft has to outlive the compile.
    private nonisolated static func withDraft<T: Sendable>(
        _ text: String, in draftDirectory: URL, of projectRoot: URL, _ body: @Sendable (String) async throws -> T
    ) async throws -> T {
        let url = draftDirectory.appendingPathComponent(".draft-\(UUID().uuidString).hexpat")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let entrypoint = url.standardizedFileURL.path.replacingOccurrences(of: projectRoot.standardizedFileURL.path + "/", with: "")
        return try await body(entrypoint)
    }

    private struct SummaryKey: Hashable {
        let sourceID: String
        let platform: String?
        let arch: String?
    }

    private struct SourceSummary {
        let text: String
        let summary: PatternSummary
    }
}

public enum PatternInputValue: Sendable {
    case integer(Int64)
    case floating(Double)
    case boolean(Bool)
    case string(String)

    var rawValue: Any {
        switch self {
        case .integer(let number):
            return number
        case .floating(let number):
            return number
        case .boolean(let flag):
            return flag
        case .string(let text):
            return text
        }
    }
}

public struct PatternSummary: Hashable, Sendable {
    public let types: [PatternTypeSummary]
    public let rootType: String?
    public let inputs: [PatternInputSummary]
    public let diagnostics: [PatternDiagnosticSummary]

    init(module: PatternModule, entrypoint: String) {
        types = module.types.map {
            PatternTypeSummary(
                name: $0.name, kind: $0.kind, size: $0.size < 0 ? nil : Int($0.size), file: $0.file == entrypoint ? nil : $0.file,
                line: Int($0.line), character: Int($0.character))
        }
        rootType = module.rootType
        inputs = module.inputs.map { PatternInputSummary(name: $0.name, typeName: $0.typeRef?.display) }
        diagnostics = module.diagnostics.map {
            PatternDiagnosticSummary(line: Int($0.line), character: Int($0.character), message: $0.message)
        }
    }

    public var decodableTypes: [PatternTypeSummary] {
        types.filter { $0.name != rootType && ($0.kind == .struct || $0.kind == .union || $0.kind == .bitfield) }
    }

    public var declaredTypes: [PatternTypeSummary] {
        types.filter { $0.name != rootType && $0.isDeclaredInSource }
    }

    public func declaredTypeName(at position: LSP.Position, in symbols: [LSP.DocumentSymbol]) -> String? {
        Self.innermostTypeName(at: position, in: symbols, scope: nil, among: Set(declaredTypes.map(\.name)))
    }

    private static func innermostTypeName(
        at position: LSP.Position, in symbols: [LSP.DocumentSymbol], scope: String?, among declared: Set<String>
    ) -> String? {
        for symbol in symbols where symbol.range.start <= position && position <= symbol.range.end {
            let name = scope.map { "\($0)::\(symbol.name)" } ?? symbol.name
            if let inner = innermostTypeName(at: position, in: symbol.children ?? [], scope: name, among: declared) {
                return inner
            }
            if declared.contains(name) {
                return name
            }
        }
        return nil
    }
}

public struct PatternTypeSummary: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let kind: PatternTypeKind
    public let size: Int?
    public let file: String?
    public let line: Int
    public let character: Int

    public var isDeclaredInSource: Bool { file == nil }
}

extension Array where Element == PatternTypeSummary {
    public func sidebarHighlights(selectedID: String?, limit: Int = SidebarHighlights.defaultLimit) -> [PatternTypeSummary] {
        Array(prefix(limit)).withSelected(selectedID, from: self, limit: limit)
    }
}

public struct PatternInputSummary: Hashable, Sendable {
    public let name: String
    public let typeName: String?
}

public struct PatternDiagnosticSummary: Hashable, Sendable {
    public let line: Int
    public let character: Int
    public let message: String
}

public struct DecodedPattern: Identifiable, Sendable {
    public let id = UUID()
    public let nodeID: UInt
    public let name: String
    public let typeName: String
    public let address: UInt64
    public let offset: UInt64
    public let size: Int?
    public let value: DecodedScalar?
    public let label: String?
    public let displayName: String?
    public let formatted: String?
    public let comment: String?
    public let color: String?
    public let hidden: Bool
    public let inlined: Bool
    public let sealed: Bool
    public let bitOffset: Int?
    public let bits: Int
    public let fields: [DecodedPattern]
    public let elements: [DecodedPattern]
    public let truncated: Bool
    public let visualizer: DecodedVisualizer?

    init(value: PatternValue) {
        nodeID = value.id
        name = value.name
        typeName = value.typeName
        address = value.address
        offset = value.offset
        size = value.size < 0 ? nil : Int(value.size)
        self.value = value.value.flatMap(DecodedScalar.init)
        label = value.label
        displayName = value.displayName
        formatted = value.formatted
        comment = value.comment
        color = value.color
        hidden = value.hidden
        inlined = value.inlined
        sealed = value.sealed
        bitOffset = value.bitOffset < 0 ? nil : value.bitOffset
        bits = Int(value.bits)
        fields = value.fields.map(DecodedPattern.init)
        elements = value.elements.map(DecodedPattern.init)
        truncated = value.truncated
        visualizer = value.visualizer.map(DecodedVisualizer.init)
    }

    public var children: [DecodedPattern] {
        fields.isEmpty ? elements : fields
    }

    public func descendant(withNodeID wanted: UInt) -> DecodedPattern? {
        if nodeID == wanted {
            return self
        }
        for child in children {
            if let match = child.descendant(withNodeID: wanted) {
                return match
            }
        }
        return nil
    }

    public var summary: String {
        if let formatted {
            return formatted
        }
        if let label {
            return label
        }
        if let value {
            return value.description
        }
        if !elements.isEmpty {
            return "[\(elements.count)]"
        }
        return ""
    }
}

public enum DecodedScalar: Sendable, Hashable, CustomStringConvertible {
    case integer(Int64)
    case unsigned(UInt64)
    case floating(Double)
    case boolean(Bool)
    case string(String)

    init?(_ value: Any) {
        switch value {
        case let number as Int64:
            self = .integer(number)
        case let number as UInt64:
            self = .unsigned(number)
        case let number as Int:
            self = .integer(Int64(number))
        case let number as Double:
            self = .floating(number)
        case let flag as Bool:
            self = .boolean(flag)
        case let text as String:
            self = .string(text)
        default:
            return nil
        }
    }

    public var number: Double? {
        switch self {
        case .integer(let number):
            return Double(number)
        case .unsigned(let number):
            return Double(number)
        case .floating(let number):
            return number
        case .boolean(let flag):
            return flag ? 1 : 0
        case .string:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .integer(let number):
            return String(number)
        case .unsigned(let number):
            return number > 9 ? String(format: "0x%llx", number) : String(number)
        case .floating(let number):
            return String(number)
        case .boolean(let flag):
            return flag ? "true" : "false"
        case .string(let text):
            return "\"\(text)\""
        }
    }
}
