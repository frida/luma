import Foundation

public struct TypeScriptProjectKey: Hashable, Sendable {
    public let languageId: String
    public let ambientDeclarations: [AmbientDeclarations]
}

@MainActor
public final class TypeScriptProject {
    public let root: URL

    private let client: LanguageClient
    private var documents: [String: TypeScriptDocument] = [:]
    private var ambientDocuments: [TypeScriptDocument] = []
    private(set) var semanticTokensLegend: LSP.SemanticTokensLegend?

    public init(root: URL) {
        self.root = root
        client = LanguageClient(root: root)
    }

    public func start(ambientDeclarations: [AmbientDeclarations]) async throws {
        client.onServerRequest = { [weak self] method in
            self?.handleServerRequest(method)
        }

        let capabilities = try await client.start()
        semanticTokensLegend = capabilities.semanticTokensProvider?.legend

        ambientDocuments = ambientDeclarations.map { declarations in
            openDocument(path: ".luma/" + declarations.fileName, text: declarations.content, languageId: "typescript")
        }
    }

    public func openDocument(path: String, text: String, languageId: String) -> TypeScriptDocument {
        let document = TypeScriptDocument(
            path: root.appendingPathComponent(path),
            text: text,
            languageId: languageId,
            project: self
        )
        if let open = documents[document.uri] {
            open.replaceText(text)
            return open
        }
        documents[document.uri] = document
        try? client.notify("textDocument/didOpen", LSP.DidOpenTextDocumentParams(
            textDocument: LSP.TextDocumentItem(uri: document.uri, languageId: languageId, version: document.version, text: text)
        ))
        document.scheduleDiagnosticsRefresh()
        return document
    }

    public func classify(_ code: String) async -> [SemanticToken] {
        let document = openDocument(path: ".luma/signature-scratch.ts", text: code + "\nexport {};", languageId: "typescript")
        return (try? await document.semanticTokens()) ?? []
    }

    public func stop() async {
        await client.stop()
        documents.removeAll()
        ambientDocuments.removeAll()
    }

    func request<Params: Encodable, Response: Decodable & Sendable>(_ method: String, _ params: Params) async throws -> Response {
        try await client.request(method, params)
    }

    func notify<Params: Encodable>(_ method: String, _ params: Params) {
        try? client.notify(method, params)
    }

    func forget(_ document: TypeScriptDocument) {
        documents[document.uri] = nil
    }

    private func handleServerRequest(_ method: String) {
        guard method == "workspace/diagnostic/refresh" else { return }
        for document in documents.values {
            document.scheduleDiagnosticsRefresh()
        }
    }
}
