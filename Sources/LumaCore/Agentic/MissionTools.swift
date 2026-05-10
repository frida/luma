import Foundation
import Frida

@MainActor
public enum MissionTools {
    public static let resultByteCap = 16 * 1024

    public static let requestUserInputToolName = "request_user_input"

    public static func registerStandard(in catalog: ToolCatalog, engine: Engine) {
        registerListDevices(in: catalog, engine: engine)
        registerListProcesses(in: catalog, engine: engine)
        registerListSessions(in: catalog, engine: engine)
        registerAttachToProcess(in: catalog, engine: engine)
        registerSpawnProcess(in: catalog, engine: engine)
        registerListModules(in: catalog, engine: engine)
        registerSummarizeRecentEvents(in: catalog, engine: engine)
        registerResolveSymbol(in: catalog, engine: engine)
        registerDisassemble(in: catalog, engine: engine)
        registerDecompile(in: catalog, engine: engine)
        registerExplainFunction(in: catalog, engine: engine)
        registerReadMemory(in: catalog, engine: engine)
        registerRecordFinding(in: catalog, engine: engine)
        registerInstallTracerHook(in: catalog, engine: engine)
        registerEvalREPL(in: catalog, engine: engine)
        registerPinAsInsight(in: catalog, engine: engine)
        registerRequestUserInput(in: catalog)
    }

    // MARK: - list_devices

    private static func registerListDevices(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_devices",
            description: "List devices reachable to Frida (local, USB-attached, network). Use when no existing session fits the goal and you need to find a target.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable") }
            let devices = await engine.deviceManager.currentDevices()
            let array: [[String: Any]] = devices.map { d in
                [
                    "id": d.id,
                    "name": d.name,
                    "kind": String(describing: d.kind),
                    "is_lost": d.isLost,
                ]
            }
            return makeResult(jsonObject: array, summary: "Listed \(devices.count) device\(devices.count == 1 ? "" : "s")")
        }
    }

    // MARK: - list_processes

    private static func registerListProcesses(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_processes",
            description: "List running processes on a Frida device. Pass name_pattern (case-insensitive regex on the process name) to narrow the result; omit it to browse all processes. Use after list_devices when looking for a pid to attach to.",
            inputSchemaJSON: """
                {"type":"object","properties":{"device_id":{"type":"string"},"name_pattern":{"type":"string","description":"Case-insensitive regex matched against process names. Omit to return everything."},"scope":{"type":"string","enum":["minimal","metadata","full"],"default":"minimal","description":"metadata adds parameters; full also adds icons (slower)"}},"required":["device_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable") }
            guard let deviceID = invocation.args["device_id"] as? String else {
                return errorResult("missing device_id")
            }
            let devices = await engine.deviceManager.currentDevices()
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                return errorResult("no device with id \(deviceID)")
            }
            let scope = parseProcessScope(invocation.args["scope"] as? String)
            let patternString = (invocation.args["name_pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let regex: Regex<AnyRegexOutput>?
            if let patternString, !patternString.isEmpty {
                do {
                    regex = try Regex(patternString).ignoresCase()
                } catch {
                    return errorResult("invalid name_pattern: \(error.localizedDescription)")
                }
            } else {
                regex = nil
            }
            do {
                let processes = try await device.enumerateProcesses(scope: scope)
                let matches: [ProcessDetails]
                if let regex {
                    matches = processes.filter { $0.name.contains(regex) }
                } else {
                    matches = processes
                }
                let array: [[String: Any]] = matches.map { p in
                    ["pid": p.pid, "name": p.name]
                }
                let payload: [String: Any] = [
                    "matches": array,
                    "match_count": matches.count,
                    "total_scanned": processes.count,
                ]
                let summary = describeProcessMatchSummary(
                    matchCount: matches.count,
                    totalScanned: processes.count,
                    pattern: patternString,
                    deviceName: device.name
                )
                return makeResult(jsonObject: payload, summary: summary)
            } catch {
                return errorResult("enumerate failed: \(error.localizedDescription)")
            }
        }
    }

    private static func describeProcessMatchSummary(matchCount: Int, totalScanned: Int, pattern: String?, deviceName: String) -> String {
        let processWord = matchCount == 1 ? "process" : "processes"
        if let pattern, !pattern.isEmpty {
            return "Matched \(matchCount) \(processWord) of \(totalScanned) on \(deviceName) (pattern: \(pattern))"
        }
        return "Found \(totalScanned) \(processWord) on \(deviceName)"
    }

    // MARK: - list_sessions

    private static func registerListSessions(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_sessions",
            description: "List sessions (attached processes) in this project. Returns id, process name, device, and whether the session is currently attached.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return ActionResult(summary: "engine unavailable", resultJSON: "[]", isError: true) }
            let sessions = engine.sessions
            let array: [[String: Any]] = sessions.map { s in
                [
                    "id": s.id.uuidString,
                    "process_name": s.processName,
                    "device_id": s.deviceID,
                    "device_name": s.deviceName,
                    "phase": s.phase.rawValue,
                    "last_known_pid": s.lastKnownPID,
                ]
            }
            return makeResult(jsonObject: array, summary: "Found \(sessions.count) session\(sessions.count == 1 ? "" : "s")")
        }
    }

    // MARK: - attach_to_process (act)

    private static func registerAttachToProcess(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "attach_to_process",
            description: "Attach Frida to an already-running process by pid. Idempotent: if a session for the same device and pid already exists, the existing session is reused (re-attaching when needed) instead of creating a duplicate. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"device_id":{"type":"string"},"pid":{"type":"integer","minimum":1}},"required":["device_id","pid"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable") }
            guard let deviceID = invocation.args["device_id"] as? String else {
                return errorResult("missing device_id")
            }
            guard let pidNumber = invocation.args["pid"] as? Int, pidNumber > 0 else {
                return errorResult("missing or invalid pid")
            }
            let pid = UInt(pidNumber)
            let devices = await engine.deviceManager.currentDevices()
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                return errorResult("no device with id \(deviceID)")
            }
            do {
                let processes = try await device.enumerateProcesses(pids: [pid], scope: .full)
                guard let process = processes.first else {
                    return errorResult("pid \(pid) not found on \(device.name)")
                }
                if let existing = findExistingAttach(in: engine, deviceID: device.id, pid: pid) {
                    return await reuseAttachSession(existing, engine: engine, device: device, process: process)
                }
                let session = ProcessSession(
                    kind: .attach,
                    deviceID: device.id,
                    deviceName: device.name,
                    processName: process.name,
                    lastKnownPID: pid
                )
                try? engine.store.save(session)
                await engine.attach(device: device, process: process, session: session)
                let payload: [String: Any] = [
                    "session_id": session.id.uuidString,
                    "process_name": process.name,
                    "pid": pid,
                ]
                return makeResult(jsonObject: payload, summary: "Attached to \(process.name) (pid \(pid)) on \(device.name)")
            } catch {
                return errorResult("attach failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - spawn_process (act)

    private static func registerSpawnProcess(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "spawn_process",
            description: "Spawn a process under Frida and attach. target_kind=program takes a 'path'; target_kind=application takes an 'identifier' (bundle ID on Apple, package name on Android). auto_resume defaults to true. Idempotent: if a session for the same device and target already exists, the existing session is reused (re-spawning when needed) instead of creating a duplicate. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"device_id":{"type":"string"},"target_kind":{"type":"string","enum":["program","application"]},"path":{"type":"string"},"identifier":{"type":"string"},"name":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"environment":{"type":"object","additionalProperties":{"type":"string"}},"working_directory":{"type":"string"},"auto_resume":{"type":"boolean","default":true}},"required":["device_id","target_kind"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable") }
            guard let deviceID = invocation.args["device_id"] as? String else {
                return errorResult("missing device_id")
            }
            let devices = await engine.deviceManager.currentDevices()
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                return errorResult("no device with id \(deviceID)")
            }
            guard let kind = invocation.args["target_kind"] as? String else {
                return errorResult("missing target_kind")
            }

            let target: SpawnConfig.Target
            switch kind {
            case "program":
                guard let path = invocation.args["path"] as? String, !path.isEmpty else {
                    return errorResult("program target requires non-empty 'path'")
                }
                target = .program(path: path)
            case "application":
                guard let identifier = invocation.args["identifier"] as? String, !identifier.isEmpty else {
                    return errorResult("application target requires non-empty 'identifier'")
                }
                let displayName = (invocation.args["name"] as? String) ?? identifier
                target = .application(identifier: identifier, name: displayName)
            default:
                return errorResult("unknown target_kind: \(kind)")
            }

            let arguments = (invocation.args["arguments"] as? [String]) ?? []
            let environment = (invocation.args["environment"] as? [String: String]) ?? [:]
            let workingDirectory = invocation.args["working_directory"] as? String
            let autoResume = (invocation.args["auto_resume"] as? Bool) ?? true

            let config = SpawnConfig(
                target: target,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                stdio: .inherit,
                autoResume: autoResume
            )
            if let existing = findExistingSpawn(in: engine, deviceID: device.id, target: target) {
                return await reuseSpawnSession(existing, engine: engine, device: device, config: config)
            }
            let session = ProcessSession(
                kind: .spawn(config),
                deviceID: device.id,
                deviceName: device.name,
                processName: config.defaultDisplayName,
                lastKnownPID: 0
            )
            try? engine.store.save(session)
            await engine.spawnAndAttach(device: device, session: session)

            let payload: [String: Any] = [
                "session_id": session.id.uuidString,
                "process_name": config.defaultDisplayName,
                "auto_resume": autoResume,
            ]
            return makeResult(jsonObject: payload, summary: "Spawned \(config.defaultDisplayName) on \(device.name)")
        }
    }

    private static func findExistingAttach(in engine: Engine, deviceID: String, pid: UInt) -> ProcessSession? {
        engine.sessions.first { session in
            guard case .attach = session.kind else { return false }
            return session.deviceID == deviceID && session.lastKnownPID == pid
        }
    }

    private static func reuseAttachSession(_ session: ProcessSession, engine: Engine, device: Device, process: ProcessDetails) async -> ActionResult {
        let payload: [String: Any] = [
            "session_id": session.id.uuidString,
            "process_name": process.name,
            "pid": process.pid,
            "reused": true,
        ]
        if engine.node(forSessionID: session.id) != nil {
            return makeResult(jsonObject: payload, summary: "Already attached to \(process.name) (pid \(process.pid)) on \(device.name)")
        }
        await engine.attach(device: device, process: process, session: session)
        return makeResult(jsonObject: payload, summary: "Re-attached to \(process.name) (pid \(process.pid)) on \(device.name)")
    }

    private static func findExistingSpawn(in engine: Engine, deviceID: String, target: SpawnConfig.Target) -> ProcessSession? {
        engine.sessions.first { session in
            guard case .spawn(let cfg) = session.kind else { return false }
            return session.deviceID == deviceID && spawnTargetsMatch(cfg.target, target)
        }
    }

    private static func reuseSpawnSession(_ session: ProcessSession, engine: Engine, device: Device, config: SpawnConfig) async -> ActionResult {
        let payload: [String: Any] = [
            "session_id": session.id.uuidString,
            "process_name": session.processName,
            "auto_resume": config.autoResume,
            "reused": true,
        ]
        if engine.node(forSessionID: session.id) != nil {
            return makeResult(jsonObject: payload, summary: "Already attached to \(session.processName) on \(device.name)")
        }
        await engine.spawnAndAttach(device: device, session: session)
        return makeResult(jsonObject: payload, summary: "Re-spawned \(session.processName) on \(device.name)")
    }

    private static func spawnTargetsMatch(_ a: SpawnConfig.Target, _ b: SpawnConfig.Target) -> Bool {
        switch (a, b) {
        case (.program(let p1), .program(let p2)):
            return p1 == p2
        case (.application(let id1, _), .application(let id2, _)):
            return id1 == id2
        default:
            return false
        }
    }

    // MARK: - list_modules

    private static func registerListModules(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_modules",
            description: "List loaded modules (libraries, frameworks, main binary) in the target process. Returns name, base, size, path.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string","description":"Session UUID to query"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)")
            }
            let mods = node.modules
            let array: [[String: Any]] = mods.map { m in
                [
                    "name": m.name,
                    "base": String(format: "0x%llx", m.base),
                    "size": m.size,
                    "path": m.path,
                ]
            }
            return makeResult(jsonObject: array, summary: "Listed \(mods.count) module\(mods.count == 1 ? "" : "s")")
        }
    }

    // MARK: - summarize_recent_events

    private static func registerSummarizeRecentEvents(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "summarize_recent_events",
            description: "Read the most recent runtime events from the global event log. Optionally filter by session_id or by kind. Useful right after a hook is enabled and the user reproduces a behavior.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"kind":{"type":"string","description":"Filter by event kind, e.g. tracer, repl"},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Max events to return (default 50)"}},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable") }
            let limit = (invocation.args["limit"] as? Int) ?? 50
            let kindFilter = invocation.args["kind"] as? String
            let sessionFilter = parseSessionID(invocation.args)

            var events = engine.eventLog.events
            if let sessionFilter {
                events = events.filter { $0.sessionID == sessionFilter }
            }
            if let kindFilter {
                events = events.filter { describeEventKind($0).contains(kindFilter) }
            }
            let tail = Array(events.suffix(limit))
            let formatter = ISO8601DateFormatter()
            let array: [[String: Any]] = tail.map { event in
                var obj: [String: Any] = [
                    "id": event.id.uuidString,
                    "kind": describeEventKind(event),
                    "timestamp": formatter.string(from: event.timestamp),
                    "summary": describeEventSummary(event),
                ]
                if let sid = event.sessionID { obj["session_id"] = sid.uuidString }
                return obj
            }
            return makeResult(jsonObject: array, summary: "Returned \(tail.count) of \(events.count) recent event\(events.count == 1 ? "" : "s")")
        }
    }

    // MARK: - resolve_symbol

    private static func registerResolveSymbol(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "resolve_symbol",
            description: "Resolve a symbol query to one or more addresses. Scope can be 'exports', 'imports', 'symbols' (broader). Query may include glob patterns like '*Keychain*'.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"scope":{"type":"string","enum":["exports","imports","symbols"]},"query":{"type":"string"}},"required":["session_id","scope","query"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)")
            }
            guard let scope = invocation.args["scope"] as? String,
                let query = invocation.args["query"] as? String
            else {
                return errorResult("missing scope or query")
            }
            do {
                let results = try await node.resolveTargets(scope: scope, query: query)
                return makeResult(jsonObject: results, summary: "Found \(results.count) match\(results.count == 1 ? "" : "es")")
            } catch {
                return errorResult("resolve failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - disassemble

    private static func registerDisassemble(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "disassemble",
            description: "Disassemble instructions starting at the given address. Returns plain-text assembly with addresses and bytes. Use after resolve_symbol to look at a function's body.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address, e.g. 0x1004500"},"count":{"type":"integer","minimum":1,"maximum":256,"default":32}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address")
            }
            let count = (invocation.args["count"] as? Int) ?? 32
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session")
            }
            let lines = await dis.disassemble(DisassemblyRequest(address: address, count: count, isDarkMode: false))
            let text = lines.map { line in
                let addr = String(format: "0x%llx", line.address)
                let asm = line.asmText.plainText
                let comment = line.commentText?.plainText ?? ""
                return "\(addr)  \(asm)\(comment.isEmpty ? "" : "  \(comment)")"
            }.joined(separator: "\n")
            let payload: [String: Any] = ["address": addrString, "count": lines.count, "text": text]
            return makeResult(jsonObject: payload, summary: "Disassembled \(lines.count) instruction\(lines.count == 1 ? "" : "s") at \(addrString)")
        }
    }

    // MARK: - read_memory

    private static func registerReadMemory(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_memory",
            description: "Read up to 4096 bytes of process memory. Returns hex bytes plus a UTF-8 best-effort decode if the bytes look like a string. Use sparingly — large reads burn tokens.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address"},"count":{"type":"integer","minimum":1,"maximum":4096,"default":256}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address")
            }
            let count = min((invocation.args["count"] as? Int) ?? 256, 4096)
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)")
            }
            do {
                let bytes = try await node.readRemoteMemory(at: address, count: count)
                let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                let asString = String(bytes: bytes, encoding: .utf8) ?? ""
                let printable = asString.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f } ? asString : nil
                let payload: [String: Any] = [
                    "address": addrString,
                    "count": bytes.count,
                    "hex": hex,
                    "string": printable as Any? ?? NSNull(),
                ]
                return makeResult(jsonObject: payload, summary: "Read \(bytes.count) bytes at \(addrString)")
            } catch {
                return errorResult("memory read failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - install_tracer_hook (act)

    private static func registerInstallTracerHook(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "install_tracer_hook",
            description: "Install a tracer hook. The 'target' is either a hex address or a symbol query — if a symbol query, it's resolved against exports first. The hook is installed disabled by default; set 'enable' true to enable immediately.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"target":{"type":"string","description":"Hex address (0x...) or symbol query"},"kind":{"type":"string","enum":["function","instruction"],"default":"function"},"enable":{"type":"boolean","default":false}},"required":["session_id","target"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let target = invocation.args["target"] as? String, !target.isEmpty else {
                return errorResult("missing target")
            }
            let kindString = (invocation.args["kind"] as? String) ?? "function"
            let kind: TracerHookKind = kindString == "instruction" ? .instruction : .function

            let address: UInt64
            if let parsed = parseHexAddress(target) {
                address = parsed
            } else {
                guard let node = engine.node(forSessionID: sessionID) else {
                    return errorResult("no attached session for id \(sessionID)")
                }
                do {
                    let resolved = try await node.resolveTargets(scope: "exports", query: target)
                    guard let first = resolved.first,
                        let addrStr = first["address"] as? String,
                        let parsed = parseHexAddress(addrStr)
                    else {
                        return errorResult("could not resolve target '\(target)'")
                    }
                    address = parsed
                } catch {
                    return errorResult("resolve failed: \(error.localizedDescription)")
                }
            }

            guard let result = await engine.addTracerHook(sessionID: sessionID, address: address, kind: kind) else {
                return errorResult("failed to install hook at \(String(format: "0x%llx", address))")
            }
            let payload: [String: Any] = [
                "instrument_id": result.instrumentID.uuidString,
                "hook_id": result.hookID.uuidString,
                "address": String(format: "0x%llx", address),
                "target": target,
            ]
            return makeResult(
                jsonObject: payload,
                summary: "Installed tracer hook at \(String(format: "0x%llx", address)) (\(target))"
            )
        }
    }

    // MARK: - eval_repl (act)

    private static func registerEvalREPL(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "eval_repl",
            description: "Run a one-off JavaScript snippet in the target process via Frida's REPL. Use for quick one-shot probes (e.g. read a global). The result string is the stringified value or any console output.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"code":{"type":"string"},"intent":{"type":"string","description":"One sentence on why you're running this"}},"required":["session_id","code","intent"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let code = invocation.args["code"] as? String, !code.isEmpty else {
                return errorResult("missing code")
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)")
            }
            let cellID = UUID()
            await node.evalInREPL(code, cellID: cellID)
            let payload: [String: Any] = [
                "cell_id": cellID.uuidString,
                "summary": "REPL evaluation submitted; results stream into the session's REPL log.",
            ]
            return makeResult(
                jsonObject: payload,
                summary: "Submitted REPL evaluation (cell \(cellID.uuidString.prefix(8)))"
            )
        }
    }

    // MARK: - record_finding (observe — auto-runs, validates evidence)

    private static func registerRecordFinding(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "record_finding",
            description: "Record a grounded finding. Every finding must reference at least one prior tool call (action) by its tool_call_id, or an event_id from summarize_recent_events. Findings without evidence are rejected.",
            inputSchemaJSON: """
                {"type":"object","properties":{"title":{"type":"string"},"body_markdown":{"type":"string"},"confidence":{"type":"string","enum":["low","medium","high"]},"kind":{"type":"string"},"session_id":{"type":"string"},"evidence":{"type":"array","minItems":1,"items":{"type":"object","properties":{"kind":{"type":"string","enum":["action","event","disasm_span","memory_read","symbol_match","insight"]},"ref":{"type":"object","description":"Either {tool_call_id} for action/observe results, or {event_id}, or a free ref"}},"required":["kind","ref"]}}},"required":["title","body_markdown","confidence","kind","evidence"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable") }
            guard let title = invocation.args["title"] as? String,
                let body = invocation.args["body_markdown"] as? String,
                let confidenceStr = invocation.args["confidence"] as? String,
                let confidence = MissionFindingConfidence(rawValue: confidenceStr),
                let kind = invocation.args["kind"] as? String,
                let evidenceList = invocation.args["evidence"] as? [[String: Any]],
                !evidenceList.isEmpty
            else {
                return errorResult("invalid arguments — title, body_markdown, confidence, kind, and non-empty evidence are required")
            }

            let actions = (try? engine.store.fetchMissionActions(missionID: invocation.mission.id)) ?? []
            let actionsByCallID = Dictionary(uniqueKeysWithValues: actions.compactMap { a -> (String, MissionAction)? in
                guard let cid = a.toolCallID else { return nil }
                return (cid, a)
            })

            var validatedEvidence: [(MissionEvidenceKind, [String: Any])] = []
            for entry in evidenceList {
                guard let kindStr = entry["kind"] as? String,
                    let evKind = MissionEvidenceKind(rawValue: kindStr),
                    let ref = entry["ref"] as? [String: Any]
                else {
                    return errorResult("evidence entry malformed: \(entry)")
                }

                if evKind == .action {
                    guard let cid = ref["tool_call_id"] as? String,
                        actionsByCallID[cid] != nil
                    else {
                        return errorResult("evidence references unknown tool_call_id; this finding is not grounded")
                    }
                }
                validatedEvidence.append((evKind, ref))
            }

            let sessionID = parseSessionID(invocation.args)
            var finding = MissionFinding(
                missionID: invocation.mission.id,
                title: title,
                bodyMarkdown: body,
                confidence: confidence,
                kind: kind,
                sessionID: sessionID
            )
            do {
                try engine.store.save(finding)
                engine.collaboration.enqueueMissionFinding(finding)
                for (evKind, ref) in validatedEvidence {
                    let refData = try JSONSerialization.data(withJSONObject: ref, options: [.sortedKeys])
                    let refJSON = String(data: refData, encoding: .utf8) ?? "{}"
                    let evidence = MissionEvidence(findingID: finding.id, kind: evKind, refJSON: refJSON)
                    try engine.store.save(evidence)
                    engine.collaboration.enqueueMissionEvidence(missionID: invocation.mission.id, evidence: evidence)
                }
            } catch {
                return errorResult("could not persist finding: \(error.localizedDescription)")
            }

            let payload: [String: Any] = [
                "finding_id": finding.id.uuidString,
                "title": title,
                "confidence": confidence.rawValue,
                "evidence_count": validatedEvidence.count,
            ]
            return makeResult(
                jsonObject: payload,
                summary: "Recorded finding \"\(title)\" (\(confidence.rawValue), \(validatedEvidence.count) evidence)"
            )
        }
    }

    // MARK: - decompile

    private static func registerDecompile(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "decompile",
            description: "Pseudo-decompile a function via radare2's pdc command. Returns C-like text. Use for higher-level reasoning when raw disassembly is too verbose.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address of function start"}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address")
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session")
            }
            let text = await dis.decompile(at: address)
            let payload: [String: Any] = ["address": addrString, "text": text]
            return makeResult(jsonObject: payload, summary: "Decompiled function at \(addrString) (\(text.split(separator: "\n").count) lines)")
        }
    }

    // MARK: - explain_function

    private static func registerExplainFunction(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "explain_function",
            description: "Get a focused natural-language explanation of a function. Internally pulls the function's disassembly + pseudo-decompile from radare2 and asks the mission's LLM to summarize. Cheaper to read than raw disassembly when you just need to understand what a function does.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address of function start"},"focus":{"type":"string","description":"Optional question to focus the explanation, e.g. 'how is the password handled here'"}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address")
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session")
            }
            let focus = (invocation.args["focus"] as? String) ?? ""

            if let viaR2AI = await tryExplainViaR2AI(disassembler: dis, address: address, addrString: addrString, focus: focus) {
                return viaR2AI
            }

            let lines = await dis.disassemble(DisassemblyRequest(address: address, count: 64, isDarkMode: false))
            let disasmText = lines.map { line in
                String(format: "0x%llx", line.address) + "  " + line.asmText.plainText
            }.joined(separator: "\n")
            let decompText = await dis.decompile(at: address)

            let summary = await summarizeViaLLM(
                engine: engine,
                providerID: invocation.mission.providerID,
                modelID: invocation.mission.modelID,
                disasm: disasmText,
                decompile: decompText,
                address: addrString,
                focus: focus
            )

            switch summary {
            case .success(let explanation):
                let payload: [String: Any] = ["address": addrString, "explanation": explanation, "source": "luma_llm"]
                return makeResult(jsonObject: payload, summary: "Explained function at \(addrString)")
            case .failure(let reason):
                return errorResult("explanation failed: \(reason)")
            }
        }
    }

    private static func tryExplainViaR2AI(
        disassembler: Disassembler,
        address: UInt64,
        addrString: String,
        focus: String
    ) async -> ActionResult? {
        let query: String = {
            var s = "Analyse and explain the function at \(addrString). Use r2 commands as needed (pdf, axt, decai). 2-4 sentences, lead with the conclusion."
            if !focus.isEmpty {
                s += " Focus on: \(focus)."
            }
            return s
        }()

        let outcome = await disassembler.runR2AISubMission(query: query, timeoutSeconds: 90)
        switch outcome {
        case .unavailable, .timeout, .failed:
            return nil
        case .completed(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let payload: [String: Any] = ["address": addrString, "explanation": trimmed, "source": "r2ai"]
            return makeResult(jsonObject: payload, summary: "Explained function at \(addrString) (via r2ai)")
        }
    }

    // MARK: - pin_as_insight (act)

    private static func registerPinAsInsight(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "pin_as_insight",
            description: "Promote a finding into a persistent AddressInsight in the session sidebar. The insight stays open across mission boundaries so the user can keep inspecting the address. Pass either a hex 'address' (resolved against the session's modules into a moduleOffset anchor) or an explicit 'anchor' object.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"finding_id":{"type":"string"},"kind":{"type":"string","enum":["disassembly","memory"],"default":"disassembly"},"address":{"type":"string","description":"Hex address (auto-anchored against modules)"},"anchor":{"type":"object","description":"Explicit AddressAnchor (matches AddressAnchor.toJSON shape)"},"title":{"type":"string"}},"required":["session_id","finding_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id")
            }
            guard let findingIDString = invocation.args["finding_id"] as? String,
                let findingID = UUID(uuidString: findingIDString),
                var finding = (try? engine.store.fetchMissionFindings(missionID: invocation.mission.id))?.first(where: { $0.id == findingID })
            else {
                return errorResult("finding_id does not match a finding in this mission")
            }

            let kindString = (invocation.args["kind"] as? String) ?? "disassembly"
            let insightKind: AddressInsight.Kind = kindString == "memory" ? .memory : .disassembly

            let anchor: AddressAnchor
            if let anchorObj = invocation.args["anchor"] as? [String: Any] {
                do {
                    anchor = try AddressAnchor.fromJSON(anchorObj)
                } catch {
                    return errorResult("anchor parse failed: \(error.localizedDescription)")
                }
            } else if let addrString = invocation.args["address"] as? String, let address = parseHexAddress(addrString) {
                guard let node = engine.node(forSessionID: sessionID) else {
                    return errorResult("no attached session for id \(sessionID)")
                }
                anchor = node.anchor(for: address)
            } else {
                return errorResult("must supply either 'address' or 'anchor'")
            }

            let title = (invocation.args["title"] as? String) ?? finding.title
            let insight = AddressInsight(sessionID: sessionID, title: title, kind: insightKind, anchor: anchor)

            do {
                try engine.store.save(insight)
                finding.pinnedInsightID = insight.id
                finding.sessionID = sessionID
                try engine.store.save(finding)
                engine.collaboration.enqueueMissionFinding(finding)
            } catch {
                return errorResult("could not persist insight: \(error.localizedDescription)")
            }

            let payload: [String: Any] = [
                "insight_id": insight.id.uuidString,
                "finding_id": finding.id.uuidString,
                "anchor": anchor.displayString,
                "kind": kindString,
            ]
            return makeResult(jsonObject: payload, summary: "Pinned finding \"\(title)\" as \(kindString) insight at \(anchor.displayString)")
        }
    }

    // MARK: - request_user_input (act, answered via Engine.submitUserInputResponse)

    private static func registerRequestUserInput(in catalog: ToolCatalog) {
        let spec = ActionSpec(
            name: requestUserInputToolName,
            description: "Pause the mission and ask the user a clarifying question. The user's text answer becomes the tool result. Optionally provide a small list of suggested options.",
            inputSchemaJSON: """
                {"type":"object","properties":{"question":{"type":"string","description":"The question to ask the user"},"options":{"type":"array","items":{"type":"string"},"description":"Optional short list of suggested answers"}},"required":["question"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { _ in
            errorResult("request_user_input must be answered via the Action Queue, not approved directly")
        }
    }

    // MARK: - helpers

    private static func parseSessionID(_ args: [String: Any]) -> UUID? {
        guard let str = args["session_id"] as? String else { return nil }
        return UUID(uuidString: str)
    }

    private static func parseProcessScope(_ raw: String?) -> Scope {
        switch raw {
        case "metadata": return .metadata
        case "full": return .full
        default: return .minimal
        }
    }

    private static func parseHexAddress(_ s: String) -> UInt64? {
        let trimmed = s.lowercased()
        if trimmed.hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed)
    }

    private static func makeResult(jsonObject: Any, summary: String) -> ActionResult {
        let data = (try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])) ?? Data("{}".utf8)
        var json = String(data: data, encoding: .utf8) ?? "{}"
        if json.utf8.count > resultByteCap {
            json = String(json.prefix(resultByteCap))
            json += "\n/* truncated — request a narrower view */"
        }
        return ActionResult(summary: summary, resultJSON: json)
    }

    private static func errorResult(_ message: String) -> ActionResult {
        ActionResult(summary: message, resultJSON: "{\"error\":\"\(escapeJSON(message))\"}", isError: true)
    }

    private enum ExplainOutcome {
        case success(String)
        case failure(String)
    }

    private static func summarizeViaLLM(
        engine: Engine,
        providerID: String,
        modelID: String,
        disasm: String,
        decompile: String,
        address: String,
        focus: String
    ) async -> ExplainOutcome {
        guard let provider = engine.llmRegistry.provider(id: providerID) else {
            return .failure("provider \(providerID) not registered")
        }
        let apiKey = (try? await engine.llmCredentials.apiKey(providerID: providerID)) ?? nil
        if provider.descriptor.capabilities.requiresAPIKey, apiKey == nil {
            return .failure("missing API key for provider \(providerID)")
        }

        let systemText = """
            You are a concise reverse-engineering assistant. Given disassembly and a pseudo-decompile of a function, produce a 2-4 sentence explanation of what the function does. Be specific about what the function reads/writes/calls. Do not restate the input.
            """
        let userPrompt: String = {
            var s = "Address: \(address)\n\nDisassembly:\n\(disasm)\n\nPseudo-C:\n\(decompile)\n"
            if !focus.isEmpty {
                s += "\nFocus on: \(focus)\n"
            }
            return s
        }()

        let request = LLMTurnRequest(
            modelID: modelID,
            systemBlocks: [LLMContentBlock(content: .text(systemText), cacheBoundary: true)],
            messages: [LLMMessage(role: .user, blocks: [.text(userPrompt)])],
            tools: [],
            maxOutputTokens: 1024,
            thinkingBudget: 0,
            temperature: 0.2
        )

        var explanation = ""
        do {
            for try await event in provider.streamTurn(request, apiKey: apiKey, baseURL: nil) {
                if case .finalMessage(_, let blocks) = event {
                    for block in blocks {
                        if case .text(let t) = block.content {
                            explanation += t
                        }
                    }
                }
            }
        } catch {
            return .failure(error.localizedDescription)
        }
        let trimmed = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure("model returned empty explanation")
        }
        return .success(trimmed)
    }

    private static func describeEventKind(_ event: RuntimeEvent) -> String {
        switch event.source {
        case .processOutput: return "process_output"
        case .script: return "script"
        case .console: return "console"
        case .repl: return "repl"
        case .instrument(_, let name): return "instrument:\(name)"
        case .spawnGating: return "spawn_gating"
        }
    }

    private static func describeEventSummary(_ event: RuntimeEvent) -> String {
        switch event.payload {
        case .consoleMessage(let msg):
            return msg.description
        case .jsError(let err):
            return err.text
        case .jsValue:
            return "[JS value]"
        case .raw:
            return "[raw payload]"
        }
    }

    private static func escapeJSON(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default: out.append(c)
            }
        }
        return out
    }
}
