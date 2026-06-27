import Foundation
#if canImport(Network)
import Network
#elseif canImport(CSoup)
import CSoup
#endif

@MainActor
public final class MCPServer {
    public typealias ToolCallObserver = @MainActor (String, [String: Any]) -> Void
    public typealias ToolResultObserver = @MainActor (String, ActionResult) -> Void
    public typealias MissionResolver = @MainActor () async -> Mission?

    public var onToolStarted: ToolCallObserver?
    public var onToolFinished: ToolResultObserver?
    public var trustsClientApprovals: Bool = false
    public let bearerToken: String

    private weak var engine: Engine?
    private let resolveMission: MissionResolver
    private let toolNames: Set<String>
    private var pendingApprovals: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var cachedMCPTools: [[String: Any]]?
    private var nextToolCallOrdinalByMission: [UUID: Int] = [:]

    #if canImport(Network)
    private let queue = DispatchQueue(label: "luma.mcp.server")
    private var listener: NWListener?
    #elseif canImport(CSoup)
    private var soupServer: UnsafeMutablePointer<SoupServer>?
    private var soupSelfPointer: UnsafeMutableRawPointer?
    #endif

    public init(
        engine: Engine,
        resolveMission: @escaping MissionResolver,
        toolNames: [String],
        bearerToken: String? = nil
    ) {
        self.engine = engine
        self.resolveMission = resolveMission
        self.toolNames = Set(toolNames)
        if let bearerToken {
            self.bearerToken = bearerToken
        } else {
            let bytes = (0..<32).map { _ in UInt8.random(in: .min...UInt8.max) }
            self.bearerToken = Data(bytes).base64EncodedString()
        }
    }

    public convenience init(engine: Engine, mission: Mission, toolNames: [String]) {
        self.init(engine: engine, resolveMission: { mission }, toolNames: toolNames)
    }

    public func approve(actionID: UUID) {
        if let cont = pendingApprovals.removeValue(forKey: actionID) {
            cont.resume(returning: .approved)
        }
    }

    public func reject(actionID: UUID, reason: String?) {
        if let cont = pendingApprovals.removeValue(forKey: actionID) {
            cont.resume(returning: .rejected(reason))
        }
    }

    fileprivate enum ApprovalDecision {
        case approved
        case rejected(String?)
        case cancelled
    }

    public func start(preferredPort: UInt16? = nil) async throws -> URL {
        #if canImport(Network)
        return try await startNetwork(preferredPort: preferredPort)
        #elseif canImport(CSoup)
        return try await startSoup(preferredPort: preferredPort)
        #else
        _ = preferredPort
        throw MCPServerError.listenerFailed("no HTTP server backend on this platform")
        #endif
    }

    public func stop() {
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #elseif canImport(CSoup)
        stopSoup()
        #endif
        for (_, cont) in pendingApprovals {
            cont.resume(returning: .cancelled)
        }
        pendingApprovals.removeAll()
    }

    // MARK: - Shared dispatch

    private func dispatch(method: String, path: String, headers: [String: String], body: Data) async -> HTTPResponse {
        if method != "POST" {
            return HTTPResponse(status: 405, body: Data("Method Not Allowed".utf8), contentType: "text/plain")
        }
        if !checkBearer(headers["authorization"]) {
            return HTTPResponse(status: 401, body: Data("Unauthorized".utf8), contentType: "text/plain")
        }
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return jsonRPCError(id: nil, code: -32_700, message: "parse error")
        }
        let rpcMethod = (request["method"] as? String) ?? ""
        let rpcID = request["id"]
        let params = (request["params"] as? [String: Any]) ?? [:]

        switch rpcMethod {
        case "initialize":
            let clientVersion = (params["protocolVersion"] as? String) ?? "2025-06-18"
            return jsonRPCResult(id: rpcID, result: [
                "protocolVersion": clientVersion,
                "capabilities": ["tools": ["listChanged": false] as [String: Any]],
                "serverInfo": ["name": "luma", "version": "1"],
                "instructions": MissionSystemPrompt.codeStyle,
            ])

        case "notifications/initialized", "notifications/cancelled", "notifications/progress":
            return HTTPResponse(status: 204, body: Data(), contentType: "application/json")

        case "tools/list":
            return jsonRPCResult(id: rpcID, result: ["tools": listMCPTools()])

        case "tools/call":
            return await handleToolCall(id: rpcID, params: params)

        default:
            return jsonRPCError(id: rpcID, code: -32_601, message: "method not found: \(rpcMethod)")
        }
    }

    private func listMCPTools() -> [[String: Any]] {
        if let cachedMCPTools { return cachedMCPTools }
        guard let engine else { return [] }
        let tools = engine.missionTools.specs()
            .filter { toolNames.isEmpty || toolNames.contains($0.name) }
            .map { spec -> [String: Any] in
                let schema = (try? JSONSerialization.jsonObject(with: Data(spec.inputSchemaJSON.utf8)))
                    ?? ["type": "object", "properties": [String: Any]()]
                return [
                    "name": spec.name,
                    "description": spec.description,
                    "inputSchema": schema,
                ]
            }
        cachedMCPTools = tools
        return tools
    }

    private func handleToolCall(id rpcID: Any?, params: [String: Any]) async -> HTTPResponse {
        guard let toolName = params["name"] as? String else {
            return jsonRPCError(id: rpcID, code: -32_602, message: "missing tool name")
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? [:]

        guard let engine else {
            return jsonRPCError(id: rpcID, code: -32_603, message: "engine unavailable")
        }
        guard let spec = engine.missionTools.spec(named: toolName) else {
            return jsonRPCError(id: rpcID, code: -32_602, message: "unknown tool: \(toolName)")
        }
        guard let mission = await resolveMission() else {
            return jsonRPCError(id: rpcID, code: -32_603, message: "no active mission to attribute this tool call to")
        }

        onToolStarted?(toolName, arguments)

        let sessionID = (arguments["session_id"] as? String).flatMap(UUID.init(uuidString:))
        let argsJSON = serializeArgs(arguments)
        let toolCallOrdinal = nextToolCallOrdinal(for: mission.id, store: engine.store)
        let toolCallID = "t\(toolCallOrdinal)"

        var action = MissionAction(
            missionID: mission.id,
            turnID: nil,
            toolName: toolName,
            argsJSON: argsJSON,
            isObserve: spec.isObserve,
            sessionID: sessionID,
            toolCallID: toolCallID
        )

        if !spec.isObserve, !trustsClientApprovals {
            try? engine.store.save(action)
            engine.collaboration.enqueueMissionAction(action)

            let decision = await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
                pendingApprovals[action.id] = cont
            }

            switch decision {
            case .rejected(let reason):
                action.status = .rejected
                action.rejectionReason = reason
                action.decidedAt = Date()
                action.completedAt = Date()
                try? engine.store.save(action)
                engine.collaboration.enqueueMissionAction(action)
                let message = reason.map { "User declined: \($0)" } ?? "User declined to run this tool."
                return jsonRPCResult(id: rpcID, result: toolCallPayload(toolCallID: toolCallID, body: message, isError: true))
            case .cancelled:
                action.status = .failed
                action.error = "mission cancelled while awaiting approval"
                action.completedAt = Date()
                try? engine.store.save(action)
                engine.collaboration.enqueueMissionAction(action)
                return jsonRPCError(id: rpcID, code: -32_000, message: "tool call cancelled")
            case .approved:
                break
            }
        }

        action.status = .running
        action.decidedAt = Date()
        try? engine.store.save(action)
        engine.collaboration.enqueueMissionAction(action)

        let invocation = ActionInvocation(
            args: arguments,
            mission: mission,
            sessionID: sessionID,
            toolCallID: toolCallID
        )

        let result: ActionResult
        do {
            result = try await engine.missionTools.execute(toolName, invocation: invocation)
        } catch {
            action.status = .failed
            action.error = error.localizedDescription
            action.completedAt = Date()
            try? engine.store.save(action)
            engine.collaboration.enqueueMissionAction(action)
            return jsonRPCResult(id: rpcID, result: toolCallPayload(toolCallID: toolCallID, body: "error: \(error.localizedDescription)", isError: true))
        }

        action.status = result.isError ? .failed : .succeeded
        action.resultJSON = result.resultJSON
        action.resultSummary = result.summary
        if result.isError { action.error = result.summary }
        action.completedAt = Date()
        try? engine.store.save(action)
        engine.collaboration.enqueueMissionAction(action)

        onToolFinished?(toolName, result)

        return jsonRPCResult(id: rpcID, result: toolCallPayload(toolCallID: toolCallID, body: result.resultJSON, isError: result.isError))
    }

    private func toolCallPayload(toolCallID: String, body: String, isError: Bool) -> [String: Any] {
        let envelope: [String: Any] = ["tool_call_id": toolCallID, "body": body]
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = #"{"body":"Failed to serialize tool result.","tool_call_id":""}"#
        }
        return [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
    }

    private func nextToolCallOrdinal(for missionID: UUID, store: ProjectStore) -> Int {
        let previous = nextToolCallOrdinalByMission[missionID] ?? ((try? store.countMissionActions(missionID: missionID)) ?? 0)
        let next = previous + 1
        nextToolCallOrdinalByMission[missionID] = next
        return next
    }

    private func serializeArgs(_ args: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
            let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    private func jsonRPCResult(id: Any?, result: [String: Any]) -> HTTPResponse {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { payload["id"] = id }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, body: body, contentType: "application/json")
    }

    private func jsonRPCError(id: Any?, code: Int, message: String) -> HTTPResponse {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { payload["id"] = id }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, body: body, contentType: "application/json")
    }

    private func idString(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let i = raw as? Int { return String(i) }
        return nil
    }

    private func checkBearer(_ presented: String?) -> Bool {
        guard let presented else { return false }
        let parts = presented.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return parts[1] == bearerToken
    }

    // MARK: - Network impl (Apple)

    #if canImport(Network)
    private func startNetwork(preferredPort: UInt16?) async throws -> URL {
        if let preferredPort, let endpoint = NWEndpoint.Port(rawValue: preferredPort) {
            if let url = try? await startListener(on: endpoint) {
                return url
            }
        }
        return try await startListener(on: .any)
    }

    private func startListener(on port: NWEndpoint.Port) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let resumed = ResumeFlag()
            listener.stateUpdateHandler = { state in
                guard !resumed.flip() else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        cont.resume(throwing: MCPServerError.listenerFailed("no port"))
                        return
                    }
                    cont.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/mcp")!)
                case .failed(let error):
                    cont.resume(throwing: error)
                case .cancelled:
                    cont.resume(throwing: MCPServerError.listenerFailed("cancelled before ready"))
                default:
                    resumed.unflip()
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                self.accept(conn)
            }
            listener.start(queue: queue)
        }
    }

    nonisolated private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(on: conn, accumulated: Data())
    }

    nonisolated private func readRequest(on conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            if error != nil { conn.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            let parsed: ParsedRequest
            switch parseHTTPRequest(buffer) {
            case .complete(let request):
                parsed = request
            case .incomplete:
                self.readRequest(on: conn, accumulated: buffer)
                return
            case .rejected(let response):
                let bytes = encodeHTTPResponse(response)
                conn.send(content: bytes, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }

            Task { @MainActor in
                let response = await self.dispatch(
                    method: parsed.method,
                    path: parsed.path,
                    headers: parsed.headers,
                    body: parsed.body
                )
                let bytes = encodeHTTPResponse(response)
                conn.send(content: bytes, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }
    #endif

    // MARK: - Soup impl (Linux/Windows)

    #if canImport(CSoup)
    private func startSoup(preferredPort: UInt16?) async throws -> URL {
        guard let server = luma_soup_server_new_default() else {
            throw MCPServerError.listenerFailed("soup_server_new returned null")
        }

        let me = Unmanaged.passRetained(self).toOpaque()
        soupSelfPointer = me

        soup_server_add_handler(server, "/mcp", { _, msg, _, _, userData in
            guard let userData, let msg else { return }
            soup_server_message_pause(msg)
            let me = Unmanaged<MCPServer>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                await me.handleSoupRequest(message: msg)
            }
        }, me, nil)

        let listenOptions = SoupServerListenOptions(rawValue: 0)
        var error: UnsafeMutablePointer<GError>?
        let port = preferredPort.map(UInt32.init) ?? 0
        let success = soup_server_listen_local(server, guint(port), listenOptions, &error)
        if success == 0 {
            let message: String
            if let err = error {
                message = String(cString: err.pointee.message)
                g_error_free(err)
            } else {
                message = "soup_server_listen_local failed"
            }
            g_object_unref(server)
            Unmanaged<MCPServer>.fromOpaque(me).release()
            soupSelfPointer = nil
            throw MCPServerError.listenerFailed(message)
        }

        guard let urisList = soup_server_get_uris(server) else {
            g_object_unref(server)
            Unmanaged<MCPServer>.fromOpaque(me).release()
            soupSelfPointer = nil
            throw MCPServerError.listenerFailed("soup_server_get_uris returned null")
        }
        guard let firstUriPtr = urisList.pointee.data else {
            g_slist_free_full(urisList, { ptr in
                if let ptr { g_uri_unref(OpaquePointer(ptr)) }
            })
            g_object_unref(server)
            Unmanaged<MCPServer>.fromOpaque(me).release()
            soupSelfPointer = nil
            throw MCPServerError.listenerFailed("soup_server_get_uris returned empty list")
        }
        let firstUri = OpaquePointer(firstUriPtr)
        let cString = g_uri_to_string(firstUri)
        defer { g_free(cString) }
        let urlString = cString.map { String(cString: $0) } ?? ""

        g_slist_free_full(urisList, { ptr in
            if let ptr { g_uri_unref(OpaquePointer(ptr)) }
        })

        soupServer = server

        guard var url = URL(string: urlString) else {
            stopSoup()
            throw MCPServerError.listenerFailed("invalid URL from libsoup: \(urlString)")
        }
        if !url.path.hasSuffix("/mcp") {
            url.append(path: "mcp")
        }
        return url
    }

    private func stopSoup() {
        if let server = soupServer {
            soup_server_disconnect(server)
            g_object_unref(server)
            soupServer = nil
        }
        if let me = soupSelfPointer {
            Unmanaged<MCPServer>.fromOpaque(me).release()
            soupSelfPointer = nil
        }
    }

    private func handleSoupRequest(message: OpaquePointer) async {
        let method = soup_server_message_get_method(message).map { String(cString: $0) } ?? ""

        let collector = HeaderCollector()
        if let reqHeaders = soup_server_message_get_request_headers(message) {
            let userData = Unmanaged.passUnretained(collector).toOpaque()
            soup_message_headers_foreach(reqHeaders, { name, value, ud in
                guard let name, let value, let ud else { return }
                let collector = Unmanaged<HeaderCollector>.fromOpaque(ud).takeUnretainedValue()
                let nameStr = String(cString: name).lowercased()
                let valueStr = String(cString: value)
                collector.headers[nameStr] = valueStr
            }, userData)
        }
        let headers = collector.headers

        var bodyData = Data()
        if let body = soup_server_message_get_request_body(message),
            let bytes = soup_message_body_flatten(body)
        {
            var size: gsize = 0
            if let raw = g_bytes_get_data(bytes, &size), size > 0 {
                bodyData = Data(bytes: raw, count: Int(size))
            }
            g_bytes_unref(bytes)
        }

        let response = await dispatch(method: method, path: "/mcp", headers: headers, body: bodyData)
        soup_server_message_set_status(message, guint(response.status), nil)
        if !response.body.isEmpty {
            response.body.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                soup_server_message_set_response(
                    message,
                    response.contentType,
                    SOUP_MEMORY_COPY,
                    base.assumingMemoryBound(to: CChar.self),
                    gsize(response.body.count)
                )
            }
        }
        soup_server_message_unpause(message)
    }
    #endif
}

public enum MCPServerError: Error {
    case listenerFailed(String)
}

private struct HTTPResponse {
    let status: Int
    let body: Data
    let contentType: String
}

#if canImport(Network)
private struct ParsedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private let maxHTTPRequestHeaderBytes = 16 * 1024
private let maxHTTPRequestBodyBytes = 8 * 1024 * 1024

private enum HTTPParseResult {
    case complete(ParsedRequest)
    case incomplete
    case rejected(HTTPResponse)
}

private func parseHTTPRequest(_ buffer: Data) -> HTTPParseResult {
    guard let separator = "\r\n\r\n".data(using: .utf8),
        let headerEnd = buffer.range(of: separator)
    else {
        if buffer.count > maxHTTPRequestHeaderBytes {
            return .rejected(HTTPResponse(status: 431, body: Data("Request Header Fields Too Large".utf8), contentType: "text/plain"))
        }
        return .incomplete
    }
    let headerData = buffer[..<headerEnd.lowerBound]
    guard headerData.count <= maxHTTPRequestHeaderBytes else {
        return .rejected(HTTPResponse(status: 431, body: Data("Request Header Fields Too Large".utf8), contentType: "text/plain"))
    }
    guard let header = String(data: headerData, encoding: .utf8) else {
        return .rejected(HTTPResponse(status: 400, body: Data("Bad Request".utf8), contentType: "text/plain"))
    }
    let lines = header.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
        return .rejected(HTTPResponse(status: 400, body: Data("Bad Request".utf8), contentType: "text/plain"))
    }
    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else {
        return .rejected(HTTPResponse(status: 400, body: Data("Bad Request".utf8), contentType: "text/plain"))
    }
    let method = parts[0]
    let path = parts[1]

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[String(name)] = value
    }
    let contentLength: Int
    if let value = headers["content-length"] {
        guard let parsed = Int(value), parsed >= 0 else {
            return .rejected(HTTPResponse(status: 400, body: Data("Bad Request".utf8), contentType: "text/plain"))
        }
        contentLength = parsed
    } else {
        contentLength = 0
    }
    guard contentLength <= maxHTTPRequestBodyBytes else {
        return .rejected(HTTPResponse(status: 413, body: Data("Payload Too Large".utf8), contentType: "text/plain"))
    }

    let bodyStart = headerEnd.upperBound
    let available = buffer.count - bodyStart
    guard available >= contentLength else { return .incomplete }
    let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
    return .complete(ParsedRequest(method: method, path: path, headers: headers, body: body))
}

private func encodeHTTPResponse(_ response: HTTPResponse) -> Data {
    let reason: String
    switch response.status {
    case 200: reason = "OK"
    case 204: reason = "No Content"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 413: reason = "Payload Too Large"
    case 405: reason = "Method Not Allowed"
    case 431: reason = "Request Header Fields Too Large"
    case 500: reason = "Internal Server Error"
    default: reason = "Status"
    }
    var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
    head += "Content-Type: \(response.contentType)\r\n"
    head += "Content-Length: \(response.body.count)\r\n"
    head += "Connection: close\r\n"
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(response.body)
    return data
}

private final class ResumeFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func flip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return true }
        done = true
        return false
    }
    func unflip() {
        lock.lock(); defer { lock.unlock() }
        done = false
    }
}
#endif

#if canImport(CSoup)
private final class HeaderCollector {
    var headers: [String: String] = [:]
}
#endif
