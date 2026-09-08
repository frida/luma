import Foundation

@MainActor
public final class TypeScriptDocument {
    public let path: URL
    public let uri: String
    public let languageId: String
    public private(set) var text: String
    public private(set) var version = 1
    public private(set) var diagnostics: [LSP.Diagnostic] = []
    public var onDiagnostics: (([LSP.Diagnostic]) -> Void)?
    public var onSemanticTokens: (([SemanticToken]) -> Void)?

    private unowned let project: TypeScriptProject
    private var diagnosticsRefresh: Task<Void, Never>?

    init(path: URL, text: String, languageId: String, project: TypeScriptProject) {
        self.path = path
        self.uri = path.absoluteString
        self.languageId = languageId
        self.text = text
        self.project = project
    }

    public func replaceText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        version += 1
        project.notify("textDocument/didChange", LSP.DidChangeTextDocumentParams(
            textDocument: LSP.VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: [LSP.WholeDocumentChange(text: newText)]
        ))
        scheduleDiagnosticsRefresh()
    }

    func scheduleDiagnosticsRefresh() {
        diagnosticsRefresh?.cancel()
        diagnosticsRefresh = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshDiagnostics()
            await refreshSemanticTokens()
        }
    }

    public func refreshSemanticTokens() async {
        let requestedVersion = version
        let tokens = (try? await semanticTokens()) ?? []
        guard requestedVersion == version else { return }
        onSemanticTokens?(tokens)
    }

    public func refreshDiagnostics() async {
        let requestedVersion = version
        guard let report: LSP.DocumentDiagnosticReport = try? await project.request("textDocument/diagnostic", documentParams),
            requestedVersion == version
        else { return }
        diagnostics = report.items ?? []
        onDiagnostics?(diagnostics)
    }

    public func completions(at position: LSP.Position, triggerCharacter: String? = nil) async throws -> LSP.CompletionList {
        let context = triggerCharacter.map { LSP.CompletionContext(triggerKind: 2, triggerCharacter: $0) }
            ?? LSP.CompletionContext(triggerKind: 1, triggerCharacter: nil)
        let response: CompletionResponse? = try await project.request(
            "textDocument/completion",
            LSP.CompletionParams(textDocument: identifier, position: position, context: context)
        )
        return response?.list ?? LSP.CompletionList(isIncomplete: false, items: [])
    }

    public func resolve(_ item: LSP.CompletionItem) async throws -> LSP.CompletionItem {
        try await project.request("completionItem/resolve", item)
    }

    public func classify(_ code: String) async -> [SemanticToken] {
        await project.classify(code)
    }

    public func hover(at position: LSP.Position) async throws -> LSP.Hover? {
        try await project.request("textDocument/hover", positionParams(position))
    }

    public func signatureHelp(at position: LSP.Position) async throws -> LSP.SignatureHelp? {
        try await project.request("textDocument/signatureHelp", positionParams(position))
    }

    public func definitions(at position: LSP.Position) async throws -> [LSP.Location] {
        let response: DefinitionResponse? = try await project.request("textDocument/definition", positionParams(position))
        return response?.locations ?? []
    }

    public func symbols() async throws -> [LSP.DocumentSymbol] {
        let response: [LSP.DocumentSymbol]? = try await project.request("textDocument/documentSymbol", documentParams)
        return response ?? []
    }

    public func semanticTokens() async throws -> [SemanticToken] {
        guard let legend = project.semanticTokensLegend else { return [] }
        let response: LSP.SemanticTokens? = try await project.request("textDocument/semanticTokens/full", documentParams)
        return SemanticToken.decode(response?.data ?? [], legend: legend)
    }

    public func close() {
        diagnosticsRefresh?.cancel()
        project.notify("textDocument/didClose", LSP.DidCloseTextDocumentParams(textDocument: identifier))
        project.forget(self)
    }

    private var identifier: LSP.TextDocumentIdentifier {
        LSP.TextDocumentIdentifier(uri: uri)
    }

    private var documentParams: LSP.DocumentParams {
        LSP.DocumentParams(textDocument: identifier)
    }

    private func positionParams(_ position: LSP.Position) -> LSP.TextDocumentPositionParams {
        LSP.TextDocumentPositionParams(textDocument: identifier, position: position)
    }

    private struct CompletionResponse: Decodable, Sendable {
        let list: LSP.CompletionList

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let items = try? container.decode([LSP.CompletionItem].self) {
                list = LSP.CompletionList(isIncomplete: false, items: items)
            } else {
                list = try container.decode(LSP.CompletionList.self)
            }
        }
    }

    private struct DefinitionResponse: Decodable, Sendable {
        let locations: [LSP.Location]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let many = try? container.decode([LSP.Location].self) {
                locations = many
            } else if let one = try? container.decode(LSP.Location.self) {
                locations = [one]
            } else {
                locations = try container.decode([LocationLink].self).map {
                    LSP.Location(uri: $0.targetUri, range: $0.targetSelectionRange)
                }
            }
        }

        private struct LocationLink: Decodable {
            let targetUri: String
            let targetSelectionRange: LSP.Range
        }
    }
}

public struct SemanticToken: Hashable, Sendable {
    public let line: Int
    public let character: Int
    public let length: Int
    public let type: String
    public let modifiers: [String]

    static func decode(_ data: [Int], legend: LSP.SemanticTokensLegend) -> [SemanticToken] {
        var tokens: [SemanticToken] = []
        var line = 0
        var character = 0
        for index in stride(from: 0, to: data.count - 4, by: 5) {
            let deltaLine = data[index]
            let deltaStart = data[index + 1]
            if deltaLine > 0 {
                line += deltaLine
                character = deltaStart
            } else {
                character += deltaStart
            }
            let typeIndex = data[index + 3]
            let modifierBits = data[index + 4]
            tokens.append(SemanticToken(
                line: line,
                character: character,
                length: data[index + 2],
                type: typeIndex < legend.tokenTypes.count ? legend.tokenTypes[typeIndex] : "",
                modifiers: legend.tokenModifiers.enumerated().compactMap { offset, name in
                    modifierBits & (1 << offset) != 0 ? name : nil
                }
            ))
        }
        return tokens
    }
}
