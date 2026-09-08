import Foundation

public enum LSP {
    public struct Position: Codable, Hashable, Sendable, Comparable {
        public var line: Int
        public var character: Int

        public init(line: Int, character: Int) {
            self.line = line
            self.character = character
        }

        public static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.line, lhs.character) < (rhs.line, rhs.character)
        }
    }

    public struct Range: Codable, Hashable, Sendable {
        public var start: Position
        public var end: Position

        public init(start: Position, end: Position) {
            self.start = start
            self.end = end
        }
    }

    public struct Location: Codable, Hashable, Sendable {
        public var uri: String
        public var range: Range
    }

    public struct TextEdit: Codable, Hashable, Sendable {
        public var range: Range
        public var newText: String
    }

    public struct MarkupContent: Codable, Hashable, Sendable {
        public var kind: String
        public var value: String
    }

    public enum Documentation: Hashable, Sendable {
        case plain(String)
        case markup(MarkupContent)

        public var text: String {
            switch self {
            case .plain(let text): return text
            case .markup(let content): return content.value
            }
        }
    }

    public struct CompletionItem: Codable, Sendable {
        public var label: String
        public var kind: Int?
        public var detail: String?
        public var documentation: Documentation?
        public var sortText: String?
        public var filterText: String?
        public var insertText: String?
        public var insertTextFormat: Int?
        public var textEdit: CompletionTextEdit?
        public var additionalTextEdits: [TextEdit]?
        public var commitCharacters: [String]?
        public var data: JSONValue?

        public var isSnippet: Bool { insertTextFormat == 2 }
    }

    public struct CompletionTextEdit: Codable, Hashable, Sendable {
        public var newText: String
        public var range: Range?
        public var insert: Range?
        public var replace: Range?

        public var replacedRange: Range? { replace ?? range }
    }

    public struct CompletionList: Codable, Sendable {
        public var isIncomplete: Bool
        public var items: [CompletionItem]
    }

    public struct Hover: Codable, Sendable {
        public var contents: Documentation
        public var range: Range?
    }

    public struct Diagnostic: Codable, Hashable, Sendable {
        public var range: Range
        public var severity: Int?
        public var code: DiagnosticCode?
        public var source: String?
        public var message: String
        public var tags: [Int]?

        public var isError: Bool { severity == nil || severity == 1 }
        public var isUnnecessary: Bool { tags?.contains(1) == true || severity == 4 }
    }

    public enum DiagnosticCode: Hashable, Sendable {
        case number(Int)
        case string(String)
    }

    public struct SignatureHelp: Codable, Sendable {
        public var signatures: [SignatureInformation]
        public var activeSignature: Int?
        public var activeParameter: Int?
    }

    public struct SignatureInformation: Codable, Sendable {
        public var label: String
        public var documentation: Documentation?
        public var parameters: [ParameterInformation]?
        public var activeParameter: Int?
    }

    public struct ParameterInformation: Codable, Sendable {
        public var label: ParameterLabel
        public var documentation: Documentation?
    }

    public enum ParameterLabel: Hashable, Sendable {
        case text(String)
        case offsets(Int, Int)
    }

    public struct DocumentSymbol: Codable, Sendable {
        public var name: String
        public var detail: String?
        public var kind: Int
        public var range: Range
        public var selectionRange: Range
        public var children: [DocumentSymbol]?
    }

    public struct SemanticTokens: Codable, Sendable {
        public var data: [Int]
    }

    public struct SemanticTokensLegend: Codable, Sendable {
        public var tokenTypes: [String]
        public var tokenModifiers: [String]
    }

    public struct ServerCapabilities: Codable, Sendable {
        public var positionEncoding: String?
        public var completionProvider: CompletionOptions?
        public var signatureHelpProvider: SignatureHelpOptions?
        public var semanticTokensProvider: SemanticTokensOptions?
    }

    public struct CompletionOptions: Codable, Sendable {
        public var triggerCharacters: [String]?
    }

    public struct SignatureHelpOptions: Codable, Sendable {
        public var triggerCharacters: [String]?
        public var retriggerCharacters: [String]?
    }

    public struct SemanticTokensOptions: Codable, Sendable {
        public var legend: SemanticTokensLegend
    }

    public struct TextDocumentIdentifier: Codable, Sendable {
        public var uri: String
    }

    public struct VersionedTextDocumentIdentifier: Codable, Sendable {
        public var uri: String
        public var version: Int
    }

    public struct TextDocumentItem: Codable, Sendable {
        public var uri: String
        public var languageId: String
        public var version: Int
        public var text: String
    }

    public struct TextDocumentPositionParams: Codable, Sendable {
        public var textDocument: TextDocumentIdentifier
        public var position: Position
    }

    public struct DidOpenTextDocumentParams: Codable, Sendable {
        public var textDocument: TextDocumentItem
    }

    public struct DidChangeTextDocumentParams: Codable, Sendable {
        public var textDocument: VersionedTextDocumentIdentifier
        public var contentChanges: [WholeDocumentChange]
    }

    public struct WholeDocumentChange: Codable, Sendable {
        public var text: String
    }

    public struct DidCloseTextDocumentParams: Codable, Sendable {
        public var textDocument: TextDocumentIdentifier
    }

    public struct CompletionParams: Codable, Sendable {
        public var textDocument: TextDocumentIdentifier
        public var position: Position
        public var context: CompletionContext?
    }

    public struct CompletionContext: Codable, Sendable {
        public var triggerKind: Int
        public var triggerCharacter: String?
    }

    public struct DocumentParams: Codable, Sendable {
        public var textDocument: TextDocumentIdentifier
    }

    public struct DocumentDiagnosticReport: Codable, Sendable {
        public var kind: String
        public var items: [Diagnostic]?
    }

    public struct InitializeParams: Codable, Sendable {
        public var processId: Int?
        public var rootUri: String
        public var capabilities: ClientCapabilities
        public var initializationOptions: InitializationOptions

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(processId, forKey: .processId)
            try container.encode(rootUri, forKey: .rootUri)
            try container.encode(capabilities, forKey: .capabilities)
            try container.encode(initializationOptions, forKey: .initializationOptions)
        }
    }

    public struct InitializationOptions: Codable, Sendable {
        public var disablePushDiagnostics: Bool
    }

    public struct ClientCapabilities: Codable, Sendable {
        public var general: GeneralCapabilities
        public var workspace: WorkspaceCapabilities
        public var textDocument: TextDocumentCapabilities
    }

    public struct WorkspaceCapabilities: Codable, Sendable {
        public var diagnostics: DiagnosticWorkspaceCapabilities
    }

    public struct DiagnosticWorkspaceCapabilities: Codable, Sendable {
        public var refreshSupport: Bool
    }

    public struct GeneralCapabilities: Codable, Sendable {
        public var positionEncodings: [String]
    }

    public struct TextDocumentCapabilities: Codable, Sendable {
        public var completion: CompletionCapabilities
        public var hover: HoverCapabilities
        public var signatureHelp: SignatureHelpCapabilities
        public var diagnostic: DiagnosticCapabilities
        public var publishDiagnostics: PublishDiagnosticsCapabilities
        public var documentSymbol: DocumentSymbolCapabilities
        public var semanticTokens: SemanticTokensClientCapabilities
    }

    public struct DiagnosticCapabilities: Codable, Sendable {
        public var dynamicRegistration: Bool
    }

    public struct PublishDiagnosticsCapabilities: Codable, Sendable {
        public var tagSupport: TagSupport

        public struct TagSupport: Codable, Sendable {
            public var valueSet: [Int]

            public init(valueSet: [Int]) {
                self.valueSet = valueSet
            }
        }

        public init(tagSupport: TagSupport) {
            self.tagSupport = tagSupport
        }
    }

    public struct SemanticTokensClientCapabilities: Codable, Sendable {
        public var requests: Requests
        public var tokenTypes: [String]
        public var tokenModifiers: [String]
        public var formats: [String]

        public struct Requests: Codable, Sendable {
            public var full: Bool

            public init(full: Bool) {
                self.full = full
            }
        }

        public init(requests: Requests, tokenTypes: [String], tokenModifiers: [String], formats: [String]) {
            self.requests = requests
            self.tokenTypes = tokenTypes
            self.tokenModifiers = tokenModifiers
            self.formats = formats
        }
    }

    public struct CompletionCapabilities: Codable, Sendable {
        public var completionItem: CompletionItemCapabilities
    }

    public struct CompletionItemCapabilities: Codable, Sendable {
        public var snippetSupport: Bool
        public var documentationFormat: [String]
        public var insertReplaceSupport: Bool
    }

    public struct HoverCapabilities: Codable, Sendable {
        public var contentFormat: [String]
    }

    public struct SignatureHelpCapabilities: Codable, Sendable {
        public var signatureInformation: SignatureInformationCapabilities
    }

    public struct SignatureInformationCapabilities: Codable, Sendable {
        public var documentationFormat: [String]
        public var parameterInformation: ParameterInformationCapabilities
    }

    public struct ParameterInformationCapabilities: Codable, Sendable {
        public var labelOffsetSupport: Bool
    }

    public struct DocumentSymbolCapabilities: Codable, Sendable {
        public var hierarchicalDocumentSymbolSupport: Bool
    }

    public struct InitializeResult: Codable, Sendable {
        public var capabilities: ServerCapabilities
    }

    public struct Empty: Codable, Sendable {
        public init() {}
    }

    public struct NoParams: Codable, Sendable {
        public init() {}
    }
}

extension LSP.Documentation: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
        } else {
            self = .markup(try container.decode(LSP.MarkupContent.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let text): try container.encode(text)
        case .markup(let content): try container.encode(content)
        }
    }
}

extension LSP.DiagnosticCode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        }
    }
}

extension LSP.ParameterLabel: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            let offsets = try container.decode([Int].self)
            self = .offsets(offsets[0], offsets[1])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .offsets(let start, let end): try container.encode([start, end])
        }
    }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
