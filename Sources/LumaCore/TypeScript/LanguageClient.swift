import Foundation
import Frida

@MainActor
final class LanguageClient {
    var onServerRequest: ((String) -> Void)?

    private let server: LanguageServer
    private let rootURI: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1
    private var pendingRequests: [Int: (Result<Data, LanguageClientError>) -> Void] = [:]
    private var pump: Task<Void, Never>?

    init(root: URL) {
        server = LanguageServer(projectRoot: root.path)
        rootURI = root.absoluteString
    }

    func start() async throws -> LSP.ServerCapabilities {
        let events = server.events
        pump = Task { @MainActor [weak self] in
            for await event in events {
                switch event {
                case .message(let json):
                    self?.handle(Data(json.utf8))
                }
            }
        }

        try await server.start()

        let initialized: LSP.InitializeResult = try await request("initialize", LSP.InitializeParams(
            processId: nil,
            rootUri: rootURI,
            capabilities: Self.clientCapabilities,
            initializationOptions: LSP.InitializationOptions(disablePushDiagnostics: true)
        ))
        try notify("initialized", LSP.Empty())

        return initialized.capabilities
    }

    private static let clientCapabilities = LSP.ClientCapabilities(
        general: LSP.GeneralCapabilities(positionEncodings: ["utf-16"]),
        workspace: LSP.WorkspaceCapabilities(diagnostics: LSP.DiagnosticWorkspaceCapabilities(refreshSupport: true)),
        textDocument: LSP.TextDocumentCapabilities(
            completion: LSP.CompletionCapabilities(
                completionItem: LSP.CompletionItemCapabilities(
                    snippetSupport: true,
                    documentationFormat: ["plaintext"],
                    insertReplaceSupport: true
                )
            ),
            hover: LSP.HoverCapabilities(contentFormat: ["markdown"]),
            signatureHelp: LSP.SignatureHelpCapabilities(
                signatureInformation: LSP.SignatureInformationCapabilities(
                    documentationFormat: ["plaintext"],
                    parameterInformation: LSP.ParameterInformationCapabilities(labelOffsetSupport: true)
                )
            ),
            diagnostic: LSP.DiagnosticCapabilities(dynamicRegistration: false),
            publishDiagnostics: LSP.PublishDiagnosticsCapabilities(
                tagSupport: LSP.PublishDiagnosticsCapabilities.TagSupport(valueSet: [1, 2])
            ),
            documentSymbol: LSP.DocumentSymbolCapabilities(hierarchicalDocumentSymbolSupport: true),
            semanticTokens: LSP.SemanticTokensClientCapabilities(
                requests: LSP.SemanticTokensClientCapabilities.Requests(full: true),
                tokenTypes: semanticTokenTypes,
                tokenModifiers: semanticTokenModifiers,
                formats: ["relative"]
            )
        )
    )

    private static let semanticTokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
        "parameter", "variable", "property", "enumMember", "event", "function", "method",
        "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator",
    ]

    private static let semanticTokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract",
        "async", "modification", "documentation", "defaultLibrary",
    ]

    func stop() async {
        let _: JSONValue? = try? await request("shutdown", LSP.NoParams())
        try? notify("exit", LSP.NoParams())
        server.stop()
        pump?.cancel()
        failPendingRequests(with: .serverStopped)
    }

    func request<Params: Encodable, Response: Decodable & Sendable>(_ method: String, _ params: Params) async throws -> Response {
        let id = nextRequestID
        nextRequestID += 1

        let message = try encoder.encode(Request(id: id, method: method, params: params))

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = { [decoder] outcome in
                continuation.resume(with: outcome.flatMap { data in
                    Self.decodeResponse(Response.self, from: data, with: decoder)
                })
            }
            do {
                try server.post(String(decoding: message, as: UTF8.self))
            } catch {
                pendingRequests[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private static func decodeResponse<Response: Decodable & Sendable>(
        _ type: Response.Type, from data: Data, with decoder: JSONDecoder
    ) -> Result<Response, LanguageClientError> {
        do {
            let response = try decoder.decode(ResponseMessage<Response>.self, from: data)
            if let error = response.error {
                return .failure(.responseError(code: error.code, message: error.message))
            }
            return .success(try response.result())
        } catch {
            return .failure(.malformedResponse(String(describing: error)))
        }
    }

    func notify<Params: Encodable>(_ method: String, _ params: Params) throws {
        let message = try encoder.encode(Notification(method: method, params: params))
        try server.post(String(decoding: message, as: UTF8.self))
    }

    private func handle(_ data: Data) {
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return }

        if let method = envelope.method {
            if let id = envelope.id {
                replyWithNull(to: id)
                onServerRequest?(method)
            }
            return
        }

        if case .number(let id) = envelope.id, let pending = pendingRequests.removeValue(forKey: id) {
            pending(.success(data))
        }
    }

    private func replyWithNull(to id: JSONRPCID) {
        guard let message = try? encoder.encode(NullReply(id: id)) else { return }
        try? server.post(String(decoding: message, as: UTF8.self))
    }

    private func failPendingRequests(with error: LanguageClientError) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, complete) in pending {
            complete(.failure(error))
        }
    }

    private struct Request<Params: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Params

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: MessageKeys.self)
            try container.encode("2.0", forKey: .jsonrpc)
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            if !(params is LSP.NoParams) {
                try container.encode(params, forKey: .params)
            }
        }
    }

    private struct Notification<Params: Encodable>: Encodable {
        let method: String
        let params: Params

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: MessageKeys.self)
            try container.encode("2.0", forKey: .jsonrpc)
            try container.encode(method, forKey: .method)
            if !(params is LSP.NoParams) {
                try container.encode(params, forKey: .params)
            }
        }
    }

    private enum MessageKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    private struct NullReply: Encodable {
        let jsonrpc = "2.0"
        let id: JSONRPCID
        let result: JSONValue = .null
    }

    private struct Envelope: Decodable {
        let id: JSONRPCID?
        let method: String?
    }

    private struct ResponseMessage<Response: Decodable>: Decodable {
        let error: ResponseError?
        private let value: Response?
        private let hasResult: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try container.decodeIfPresent(ResponseError.self, forKey: .error)
            hasResult = container.contains(.result)
            value = try container.decodeIfPresent(Response.self, forKey: .result)
        }

        func result() throws -> Response {
            if let value {
                return value
            }
            if hasResult, let nothing = Optional<Any>.none as? Response {
                return nothing
            }
            throw LanguageClientError.malformedResponse("missing result")
        }

        private enum CodingKeys: String, CodingKey {
            case error
            case result
        }
    }

    private struct ResponseError: Decodable {
        let code: Int
        let message: String
    }
}

enum JSONRPCID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        }
    }
}

public enum LanguageClientError: Swift.Error, Sendable, CustomStringConvertible {
    case responseError(code: Int, message: String)
    case malformedResponse(String)
    case serverStopped

    public var description: String {
        switch self {
        case .responseError(let code, let message): return "Language server error \(code): \(message)"
        case .malformedResponse(let detail): return "Malformed language server response: \(detail)"
        case .serverStopped: return "Language server stopped"
        }
    }
}
