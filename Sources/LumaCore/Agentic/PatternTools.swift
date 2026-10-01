import Foundation

extension MissionTools {
    static func registerPatterns(in catalog: ToolCatalog, engine: Engine) {
        registerListPatterns(in: catalog, engine: engine)
        registerReadPattern(in: catalog, engine: engine)
        registerCheckPattern(in: catalog, engine: engine)
        registerWritePattern(in: catalog, engine: engine)
        registerDecodeMemory(in: catalog, engine: engine)
        registerCallPatternFunction(in: catalog, engine: engine)
        registerPlacePattern(in: catalog, engine: engine)
    }

    private static let patternSourceSchema = """
        "pattern_id":{"type":"string","description":"Library file, as list_patterns names it, e.g. \\"macho.hexpat\\""},\
        "source":{"type":"string","description":"Inline pattern source, instead of pattern_id"},\
        "type":{"type":"string","description":"Type to decode; defaults to the source's root placement"}
        """

    private static func registerListPatterns(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_patterns",
            description: """
                List the pattern library: ImHex-style pattern language files (.hexpat patterns, .pat \
                libraries) with the types each declares and any compile errors. Patterns describe binary \
                layouts; decode_memory applies one to process memory.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let listed = await engine.describePatternLibrary()
            return makeResult(jsonObject: listed, summary: "\(listed.count) pattern file\(listed.count == 1 ? "" : "s")")
        }
    }

    private static func registerReadPattern(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_pattern",
            description: "Read a pattern library file's source.",
            inputSchemaJSON: """
                {"type":"object","properties":{"pattern_id":{"type":"string"}},"required":["pattern_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let id = invocation.args["pattern_id"] as? String, let source = engine.patterns.source(withID: id) else {
                return errorResult("no pattern file with that pattern_id; see list_patterns", code: .notFound)
            }
            return makeResult(jsonObject: ["id": source.id, "source": source.text], summary: "Read \(source.id)")
        }
    }

    private static func registerCheckPattern(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "check_pattern",
            description: """
                Compile pattern source without saving it, and report its diagnostics and the types it \
                declares. Use to iterate on a pattern before write_pattern.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"source":{"type":"string"}},"required":["source"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let text = invocation.args["source"] as? String else {
                return errorResult("source is required", code: .invalidInput)
            }
            do {
                let summary = try await engine.patternDecoder.summary(ofText: text)
                return makeResult(
                    jsonObject: summary.jsonObject,
                    summary: summary.diagnostics.isEmpty ? "Compiles cleanly" : "\(summary.diagnostics.count) diagnostic(s)")
            } catch {
                return errorResult("compile failed: \(error.localizedDescription)", code: .failed)
            }
        }
    }

    private static func registerWritePattern(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "write_pattern",
            description: """
                Create or replace a pattern library file. The id is a file name ending in .hexpat \
                (a pattern) or .pat (a library other files import). Returns the diagnostics of what was \
                written. Requires user approval.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"pattern_id":{"type":"string","description":"e.g. \\"elf.hexpat\\""},"source":{"type":"string"}},"required":["pattern_id","source"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false,
            codePreview: CodePreviewArg(field: "source", language: .patternLanguage)
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let id = invocation.args["pattern_id"] as? String, let text = invocation.args["source"] as? String else {
                return errorResult("pattern_id and source are required", code: .invalidInput)
            }
            let url = URL(fileURLWithPath: id)
            guard id == url.lastPathComponent, !id.hasPrefix("."), PatternSource.extensions.contains(url.pathExtension.lowercased()) else {
                return errorResult("pattern_id must be a plain file name ending in .hexpat or .pat", code: .invalidInput)
            }
            do {
                try engine.patterns.write(text, to: id)
                let summary = try await engine.patternDecoder.summary(ofText: text)
                var payload = summary.jsonObject
                payload["id"] = id
                return makeResult(jsonObject: payload, summary: "Wrote \(id)")
            } catch {
                return errorResult("write failed: \(error.localizedDescription)", code: .failed)
            }
        }
    }

    private static func registerDecodeMemory(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "decode_memory",
            description: """
                Decode process memory at an address with a pattern type, and return the decoded tree: \
                each node's name, type, address, size and formatted value. Memory is read as far as the \
                type needs, up to 1 MiB. The tree is cut at 'depth' levels, with arrays showing their \
                first 'element_limit' elements; use 'path' (e.g. \\"commands[3].segname\\") to start \
                deeper instead of widening the whole tree.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address"},\
                \(patternSourceSchema),\
                "path":{"type":"string","description":"Node to return, as field names and [index] steps from the root"},\
                "depth":{"type":"integer","minimum":0,"maximum":8,"default":2},\
                "element_limit":{"type":"integer","minimum":0,"maximum":256,"default":8}},\
                "required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            do {
                let request = try await PatternRequest(invocation.args, engine: engine)
                let decoding = try await request.decode(engine: engine)
                let node = try decoding.value.descendant(at: request.path)
                var payload = node.projection(
                    depth: min((invocation.args["depth"] as? Int) ?? 2, 8),
                    elementLimit: min((invocation.args["element_limit"] as? Int) ?? 8, 256))
                payload["bytes_read"] = decoding.data.count
                return makeResult(
                    jsonObject: payload, summary: "Decoded \(request.typeName) at \(String(format: "0x%llx", request.address))")
            } catch {
                return errorResult(error.localizedDescription, code: .failed)
            }
        }
    }

    private static func registerCallPatternFunction(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "call_pattern_function",
            description: """
                Decode like decode_memory, then call one of the pattern's functions with the node at \
                'path', the way ImHex's button visualizer does, and return what it printed. Functions run \
                in the pattern evaluator and cannot touch the process.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address"},\
                \(patternSourceSchema),\
                "path":{"type":"string","description":"Node to pass, as field names and [index] steps from the root"},\
                "function":{"type":"string"}},\
                "required":["session_id","address","function"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let function = invocation.args["function"] as? String else {
                return errorResult("function is required", code: .invalidInput)
            }
            do {
                let request = try await PatternRequest(invocation.args, engine: engine)
                let decoding = try await request.decode(engine: engine)
                let node = try decoding.value.descendant(at: request.path)
                guard let target = engine.node(forSessionID: request.sessionID)?.processInfo else {
                    throw PatternMemoryError.detached
                }
                let output = try await engine.patternDecoder.callFunction(
                    function, on: node.nodeID, ofText: request.text, typeName: request.typeName, data: decoding.data,
                    address: request.address, platform: target.platform, arch: target.arch)
                return makeResult(jsonObject: ["output": output], summary: "Called \(function)")
            } catch {
                return errorResult(error.localizedDescription, code: .failed)
            }
        }
    }

    private static func registerPlacePattern(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "place_pattern",
            description: """
                Decode a pattern type in a memory insight's view, so the user sees the fields outlined \
                over its hex dump. 'offset' is relative to the insight's address. Pin the memory with \
                pin_as_insight first. Requires user approval.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"insight_id":{"type":"string"},\
                "pattern_id":{"type":"string"},"type":{"type":"string"},"offset":{"type":"integer","minimum":0,"default":0}},\
                "required":["session_id","insight_id","pattern_id","type"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let idString = invocation.args["insight_id"] as? String, let insightID = UUID(uuidString: idString),
                let insight = engine.insightsBySession[sessionID]?.first(where: { $0.id == insightID })
            else {
                return errorResult("no such insight on this session; see list_address_insights", code: .notFound)
            }
            guard insight.kind == .memory else {
                return errorResult("patterns can only be placed on memory insights", code: .invalidInput)
            }
            guard let patternID = invocation.args["pattern_id"] as? String, engine.patterns.source(withID: patternID) != nil,
                let typeName = invocation.args["type"] as? String
            else {
                return errorResult("pattern_id must name a library file and type is required", code: .invalidInput)
            }
            let placement = PatternPlacement(sourceID: patternID, typeName: typeName, offset: (invocation.args["offset"] as? Int) ?? 0)
            engine.setPlacements(insight.placements + [placement], forInsight: insight)
            return makeResult(
                jsonObject: ["insight_id": insightID.uuidString, "placement_id": placement.id.uuidString],
                summary: "Placed \(typeName) on \(engine.displayTitle(for: insight))")
        }
    }
}

private struct PatternRequest {
    let sessionID: UUID
    let address: UInt64
    let text: String
    let typeName: String
    let path: PatternPath

    private static let initialByteCount = 0x200

    @MainActor
    init(_ args: [String: Any], engine: Engine) async throws {
        guard let sessionID = MissionTools.parseSessionID(args) else { throw PatternRequestError("missing or invalid session_id") }
        guard let addressText = args["address"] as? String, let address = MissionTools.parseHexAddress(addressText) else {
            throw PatternRequestError("missing or invalid address")
        }
        if let id = args["pattern_id"] as? String {
            guard let source = engine.patterns.source(withID: id) else {
                throw PatternRequestError("no pattern file \(id); see list_patterns")
            }
            text = source.text
        } else if let source = args["source"] as? String {
            text = source
        } else {
            throw PatternRequestError("pass pattern_id or source")
        }
        if let typeName = args["type"] as? String {
            self.typeName = typeName
        } else {
            let summary = try await engine.patternDecoder.summary(ofText: text)
            guard let rootType = summary.rootType else {
                let names = summary.decodableTypes.map(\.name).joined(separator: ", ")
                throw PatternRequestError("the source places nothing at its root; pass type, one of: \(names)")
            }
            typeName = rootType
        }
        self.sessionID = sessionID
        self.address = address
        path = try PatternPath((args["path"] as? String) ?? "")
    }

    @MainActor
    func decode(engine: Engine) async throws -> PatternMemoryDecoding {
        try await engine.decodePattern(
            text: text, typeName: typeName, sessionID: sessionID, address: address, byteCount: Self.initialByteCount)
    }
}

private struct PatternRequestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
