import Foundation
import Frida

@MainActor
public final class PatternDecoder {
    private let compiler = PatternCompiler()
    private var summaries: [SummaryKey: SourceSummary] = [:]

    public init() {}

    public func summary(of source: PatternSource, platform: String? = nil, arch: String? = nil) async throws -> PatternSummary {
        let key = SummaryKey(sourceID: source.id, platform: platform, arch: arch)
        if let cached = summaries[key], cached.text == source.text {
            return cached.summary
        }
        let summary = try await summary(ofText: source.text, platform: platform, arch: arch)
        summaries[key] = SourceSummary(text: source.text, summary: summary)
        return summary
    }

    public func summary(ofText text: String, platform: String? = nil, arch: String? = nil) async throws -> PatternSummary {
        PatternSummary(module: try await Self.compile(text, platform: platform, arch: arch, using: compiler))
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
        try await decode(
            text: source.text, typeName: typeName, data: data, address: address, platform: platform, arch: arch, inputs: inputs)
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
        try await Self.decode(
            text, typeName: typeName, data: Array(data), address: address, platform: platform, arch: arch, inputs: inputs,
            using: compiler)
    }

    private nonisolated static func decode(
        _ text: String,
        typeName: String,
        data: [UInt8],
        address: UInt64,
        platform: String?,
        arch: String?,
        inputs: [String: PatternInputValue],
        using compiler: PatternCompiler
    ) async throws -> DecodedPattern {
        let module = try await compile(text, platform: platform, arch: arch, using: compiler)
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
        try await callFunction(
            function, on: nodeID, ofText: source.text, typeName: typeName, data: data, address: address, platform: platform,
            arch: arch)
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
        try await Self.callFunction(
            function, on: nodeID, of: text, typeName: typeName, data: Array(data), address: address, platform: platform,
            arch: arch, using: compiler)
    }

    private nonisolated static func callFunction(
        _ function: String,
        on nodeID: UInt,
        of text: String,
        typeName: String,
        data: [UInt8],
        address: UInt64,
        platform: String?,
        arch: String?,
        using compiler: PatternCompiler
    ) async throws -> String {
        let module = try await compile(text, platform: platform, arch: arch, using: compiler)
        return try await module.callFunction(typeName: typeName, data: data, address: address, pattern: nodeID, function: function)
    }

    private nonisolated static func compile(
        _ text: String, platform: String?, arch: String?, using compiler: PatternCompiler
    ) async throws -> PatternModule {
        try await compiler.compile(source: text, platform: platform, arch: arch)
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

    init(module: PatternModule) {
        types = module.types.map {
            PatternTypeSummary(
                name: $0.name, kind: $0.kind, size: $0.size < 0 ? nil : Int($0.size), file: $0.file,
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
