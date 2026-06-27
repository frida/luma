import Foundation
import Frida
import SwiftyR2

@MainActor
public enum MissionTools {
    public static let resultByteCap = 16 * 1024
    public static let stringValueByteCap = 2 * 1024

    public static let requestUserInputToolName = "request_user_input"

    public static func registerStandard(in catalog: ToolCatalog, engine: Engine) {
        registerListDevices(in: catalog, engine: engine)
        registerListProcesses(in: catalog, engine: engine)
        registerListSessions(in: catalog, engine: engine)
        registerAttachToProcess(in: catalog, engine: engine)
        registerSpawnProcess(in: catalog, engine: engine)
        registerListModules(in: catalog, engine: engine)
        registerListThreads(in: catalog, engine: engine)
        registerListSessionInstruments(in: catalog, engine: engine)
        registerArmSession(in: catalog, engine: engine)
        registerDisarmSession(in: catalog, engine: engine)
        registerResumeSession(in: catalog, engine: engine)
        registerSummarizeRecentEvents(in: catalog, engine: engine)
        registerWaitForEvent(in: catalog, engine: engine)
        registerReadEvent(in: catalog, engine: engine)
        registerResolveSymbol(in: catalog, engine: engine)
        registerDisassemble(in: catalog, engine: engine)
        registerR2Cmd(in: catalog, engine: engine)
        registerDecompile(in: catalog, engine: engine)
        registerExplainFunction(in: catalog, engine: engine)
        registerSuggestFunctionName(in: catalog, engine: engine)
        registerSuggestFunctionSignature(in: catalog, engine: engine)
        registerSuggestLocalNames(in: catalog, engine: engine)
        registerFindVulnerabilities(in: catalog, engine: engine)
        registerReadMemory(in: catalog, engine: engine)
        registerWriteMemory(in: catalog, engine: engine)
        registerRecordFinding(in: catalog, engine: engine)
        registerListFindings(in: catalog, engine: engine)
        registerReadFinding(in: catalog, engine: engine)
        registerListNotebookEntries(in: catalog, engine: engine)
        registerReadNotebookEntry(in: catalog, engine: engine)
        registerCreateNotebookEntry(in: catalog, engine: engine)
        registerUpdateNotebookEntry(in: catalog, engine: engine)
        registerDeleteNotebookEntry(in: catalog, engine: engine)
        registerEvalREPL(in: catalog, engine: engine)
        registerInstallTracerHook(in: catalog, engine: engine)
        registerListTracerHooks(in: catalog, engine: engine)
        registerReadTracerHook(in: catalog, engine: engine)
        registerUpdateTracerHook(in: catalog, engine: engine)
        registerEditTracerHook(in: catalog, engine: engine)
        registerRemoveTracerHook(in: catalog, engine: engine)
        registerListInstruments(in: catalog, engine: engine)
        registerAttachInstrument(in: catalog, engine: engine)
        registerReadCustomInstrument(in: catalog, engine: engine)
        registerCreateCustomInstrument(in: catalog, engine: engine)
        registerUpdateCustomInstrument(in: catalog, engine: engine)
        registerDeleteCustomInstrument(in: catalog, engine: engine)
        registerListCustomInstrumentFiles(in: catalog, engine: engine)
        registerReadCustomInstrumentFile(in: catalog, engine: engine)
        registerWriteCustomInstrumentFile(in: catalog, engine: engine)
        registerEditCustomInstrumentFile(in: catalog, engine: engine)
        registerDeleteCustomInstrumentFile(in: catalog, engine: engine)
        registerRenameCustomInstrumentFile(in: catalog, engine: engine)
        registerSetCustomInstrumentEntrypoint(in: catalog, engine: engine)
        registerReadTracerHandlerTemplate(in: catalog)
        registerReadCustomInstrumentTemplate(in: catalog)
        registerReadCustomInstrumentTypings(in: catalog, engine: engine)
        registerLookupFridaAPI(in: catalog)
        registerListPackages(in: catalog, engine: engine)
        registerInstallPackage(in: catalog, engine: engine)
        registerRemovePackage(in: catalog, engine: engine)
        registerStartThreadTrace(in: catalog, engine: engine)
        registerStopTrace(in: catalog, engine: engine)
        registerListTraces(in: catalog, engine: engine)
        registerSummarizeTrace(in: catalog, engine: engine)
        registerListTraceFunctionCalls(in: catalog, engine: engine)
        registerReadTraceFunctionCall(in: catalog, engine: engine)
        registerReadTraceRegisterState(in: catalog, engine: engine)
        registerPinAsInsight(in: catalog, engine: engine)
        registerListAddressInsights(in: catalog, engine: engine)
        registerUnpinInsight(in: catalog, engine: engine)
        registerRenameInsight(in: catalog, engine: engine)
        registerDetachSession(in: catalog, engine: engine)
        registerReadWidgetState(in: catalog, engine: engine)
        registerInvokeWidgetAction(in: catalog, engine: engine)
        registerSubmitConsoleInput(in: catalog, engine: engine)
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
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
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
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let deviceID = invocation.args["device_id"] as? String else {
                return errorResult("missing device_id", code: .invalidInput)
            }
            let devices = await engine.deviceManager.currentDevices()
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                return errorResult("no device with id \(deviceID)", code: .notFound)
            }
            let scope = parseProcessScope(invocation.args["scope"] as? String)
            let patternString = (invocation.args["name_pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let regex: Regex<AnyRegexOutput>?
            if let patternString, !patternString.isEmpty {
                do {
                    regex = try Regex(patternString).ignoresCase()
                } catch {
                    return errorResult("invalid name_pattern: \(error.localizedDescription)", code: .invalidInput)
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
                var entry: [String: Any] = [
                    "id": s.id.uuidString,
                    "process_name": s.processName,
                    "device_id": s.deviceID,
                    "device_name": s.deviceName,
                    "phase": phaseDescription(s.phase),
                    "last_known_pid": s.lastKnownPID,
                ]
                if let error = s.lastError, !error.isEmpty {
                    entry["last_error"] = error
                }
                return entry
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
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let deviceID = invocation.args["device_id"] as? String else {
                return errorResult("missing device_id", code: .invalidInput)
            }
            guard let pidNumber = invocation.args["pid"] as? Int, pidNumber > 0 else {
                return errorResult("missing or invalid pid", code: .invalidInput)
            }
            let pid = UInt(pidNumber)
            let devices = await engine.deviceManager.currentDevices()
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                return errorResult("no device with id \(deviceID)", code: .notFound)
            }
            do {
                let processes = try await device.enumerateProcesses(pids: [pid], scope: .full)
                guard let process = processes.first else {
                    return errorResult("pid \(pid) not found on \(device.name)", code: .notFound)
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
                engine.createSession(session)
                do {
                    let attached = try await engine.attach(device: device, process: process, session: session)
                    return attachSuccessResult(session: attached, process: process, device: device, reused: false, successVerb: "Attached")
                } catch {
                    return errorResult("attach failed for \(process.name) (pid \(pid)) on \(device.name): \(error.localizedDescription)")
                }
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
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let deviceID = invocation.args["device_id"] as? String else {
                return errorResult("missing device_id", code: .invalidInput)
            }
            let devices = await engine.deviceManager.currentDevices()
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                return errorResult("no device with id \(deviceID)", code: .notFound)
            }
            guard let kind = invocation.args["target_kind"] as? String else {
                return errorResult("missing target_kind", code: .invalidInput)
            }

            let target: SpawnConfig.Target
            switch kind {
            case "program":
                guard let path = invocation.args["path"] as? String, !path.isEmpty else {
                    return errorResult("program target requires non-empty 'path'", code: .invalidInput)
                }
                target = .program(path: path)
            case "application":
                guard let identifier = invocation.args["identifier"] as? String, !identifier.isEmpty else {
                    return errorResult("application target requires non-empty 'identifier'", code: .invalidInput)
                }
                let displayName = (invocation.args["name"] as? String) ?? identifier
                target = .application(identifier: identifier, name: displayName)
            default:
                return errorResult("unknown target_kind: \(kind)", code: .invalidInput)
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
            engine.createSession(session)
            do {
                let attached = try await engine.spawnAndAttach(device: device, session: session)
                return spawnSuccessResult(session: attached, processName: config.defaultDisplayName, device: device, autoResume: autoResume, reused: false, successVerb: "Spawned")
            } catch {
                return errorResult("spawn failed for \(config.defaultDisplayName) on \(device.name): \(error.localizedDescription)")
            }
        }
    }

    private static func findExistingAttach(in engine: Engine, deviceID: String, pid: UInt) -> ProcessSession? {
        engine.sessions.first { session in
            guard case .attach = session.kind else { return false }
            return session.deviceID == deviceID && session.lastKnownPID == pid
        }
    }

    private static func reuseAttachSession(_ session: ProcessSession, engine: Engine, device: Device, process: ProcessDetails) async -> ActionResult {
        if engine.node(forSessionID: session.id) != nil {
            return attachSuccessResult(session: session, process: process, device: device, reused: true, successVerb: "Already attached")
        }
        do {
            let attached = try await engine.attach(device: device, process: process, session: session)
            return attachSuccessResult(session: attached, process: process, device: device, reused: true, successVerb: "Re-attached")
        } catch {
            return errorResult("attach failed for \(process.name) (pid \(process.pid)) on \(device.name): \(error.localizedDescription)")
        }
    }

    private static func findExistingSpawn(in engine: Engine, deviceID: String, target: SpawnConfig.Target) -> ProcessSession? {
        engine.sessions.first { session in
            guard case .spawn(let cfg) = session.kind else { return false }
            return session.deviceID == deviceID && spawnTargetsMatch(cfg.target, target)
        }
    }

    private static func reuseSpawnSession(_ session: ProcessSession, engine: Engine, device: Device, config: SpawnConfig) async -> ActionResult {
        if engine.node(forSessionID: session.id) != nil {
            return spawnSuccessResult(session: session, processName: session.processName, device: device, autoResume: config.autoResume, reused: true, successVerb: "Already attached to")
        }
        do {
            let attached = try await engine.spawnAndAttach(device: device, session: session)
            return spawnSuccessResult(session: attached, processName: session.processName, device: device, autoResume: config.autoResume, reused: true, successVerb: "Re-spawned")
        } catch {
            return errorResult("spawn failed for \(session.processName) on \(device.name): \(error.localizedDescription)")
        }
    }

    private static func attachSuccessResult(session: ProcessSession, process: ProcessDetails, device: Device, reused: Bool, successVerb: String) -> ActionResult {
        var payload: [String: Any] = [
            "session_id": session.id.uuidString,
            "process_name": process.name,
            "pid": process.pid,
            "phase": phaseDescription(session.phase),
        ]
        if reused { payload["reused"] = true }
        return makeResult(jsonObject: payload, summary: "\(successVerb) to \(process.name) (pid \(process.pid)) on \(device.name)")
    }

    private static func spawnSuccessResult(session: ProcessSession, processName: String, device: Device, autoResume: Bool, reused: Bool, successVerb: String) -> ActionResult {
        var payload: [String: Any] = [
            "session_id": session.id.uuidString,
            "process_name": processName,
            "auto_resume": autoResume,
            "phase": phaseDescription(session.phase),
            "pid": session.lastKnownPID,
        ]
        if reused { payload["reused"] = true }
        return makeResult(jsonObject: payload, summary: "\(successVerb) \(processName) on \(device.name)")
    }

    private static func phaseDescription(_ phase: ProcessSession.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .attaching: return "attaching"
        case .awaitingInitialResume: return "awaiting_initial_resume"
        case .attached: return "attached"
        }
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
            description: "List loaded modules (libraries, frameworks, main binary) in the target process. Real processes can have ~1000 modules, so the result is filtered and capped by default. Pass 'match' (case-insensitive substring matched against name and path) to narrow, 'offset'/'limit' to page, and 'detail' to choose projection. Default detail 'summary' returns {name, base}; 'full' adds size and path. Response shape: {total, matched, offset, returned, truncated, modules}.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string","description":"Session UUID to query"},"match":{"type":"string","description":"Case-insensitive substring matched against module name and path. Omit to consider all modules."},"offset":{"type":"integer","minimum":0,"description":"Number of matched modules to skip before returning rows (default 0)."},"limit":{"type":"integer","minimum":1,"maximum":500,"description":"Max modules to return (default 64)"},"detail":{"type":"string","enum":["summary","full"],"description":"'summary' = name+base only (default). 'full' adds size and path."}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)", code: .notFound)
            }
            let all = node.modules
            let needle = (invocation.args["match"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let matched: [ProcessModule]
            if let needle {
                let lowered = needle.lowercased()
                matched = all.filter { $0.name.lowercased().contains(lowered) || $0.path.lowercased().contains(lowered) }
            } else {
                matched = all
            }
            let offset = max(0, (invocation.args["offset"] as? Int) ?? 0)
            let limit = max(1, min(500, (invocation.args["limit"] as? Int) ?? 64))
            let returned = Array(matched.dropFirst(offset).prefix(limit))
            let truncated = matched.count > offset + returned.count
            let detail = (invocation.args["detail"] as? String) ?? "summary"
            let modulesJSON: [[String: Any]] = returned.map { m in
                var entry: [String: Any] = [
                    "name": m.name,
                    "base": String(format: "0x%llx", m.base),
                ]
                if detail == "full" {
                    entry["size"] = m.size
                    entry["path"] = m.path
                }
                return entry
            }
            let payload: [String: Any] = [
                "total": all.count,
                "matched": matched.count,
                "offset": offset,
                "returned": returned.count,
                "truncated": truncated,
                "modules": modulesJSON,
            ]
            let summary: String
            if let needle {
                summary = "Matched \(matched.count)/\(all.count) module\(matched.count == 1 ? "" : "s") for '\(needle)'\(truncated ? " (returning \(returned.count))" : "")"
            } else {
                summary = "\(all.count) module\(all.count == 1 ? "" : "s") loaded\(truncated ? "; returning \(returned.count) from offset \(offset)" : "")"
            }
            return makeResult(jsonObject: payload, summary: summary)
        }
    }

    // MARK: - list_threads

    private static func registerListThreads(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_threads",
            description: "List the target process's known threads. Thread-heavy processes can have hundreds of rows, so the result is capped by default. Pass 'offset'/'limit' to page and 'detail' to choose projection. Default detail 'summary' returns {id, name}; 'full' also includes entrypoint. Live for attached sessions; falls back to the last cached snapshot when the session is detached. Response shape: {total, offset, returned, truncated, threads}.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"offset":{"type":"integer","minimum":0,"description":"Number of threads to skip before returning rows (default 0)."},"limit":{"type":"integer","minimum":1,"maximum":500,"description":"Max threads to return (default 64)."},"detail":{"type":"string","enum":["summary","full"],"description":"'summary' = id+name only (default). 'full' adds entrypoint."}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            let liveThreads = engine.node(forSessionID: sessionID)?.threads
            let cached = engine.sessions.first(where: { $0.id == sessionID })?.lastKnownThreads
            guard let threads = liveThreads ?? cached else {
                return errorResult("no thread data for session \(sessionID)", code: .notFound)
            }
            let offset = max(0, (invocation.args["offset"] as? Int) ?? 0)
            let limit = max(1, min(500, (invocation.args["limit"] as? Int) ?? 64))
            let returned = Array(threads.dropFirst(offset).prefix(limit))
            let truncated = threads.count > offset + returned.count
            let detail = (invocation.args["detail"] as? String) ?? "summary"
            let array: [[String: Any]] = returned.map { threadJSON($0, detail: detail) }
            let payload: [String: Any] = [
                "total": threads.count,
                "offset": offset,
                "returned": returned.count,
                "truncated": truncated,
                "threads": array,
            ]
            let suffix = truncated ? "; returning \(returned.count) from offset \(offset)" : ""
            return makeResult(jsonObject: payload, summary: "Listed \(threads.count) thread\(threads.count == 1 ? "" : "s")\(suffix)")
        }
    }

    private static func threadJSON(_ thread: ProcessThread, detail: String) -> [String: Any] {
        var obj: [String: Any] = ["id": Int(thread.id)]
        if let name = thread.name {
            obj["name"] = name
        }
        if detail == "full", let entrypoint = thread.entrypoint {
            var ep: [String: Any] = ["routine": String(format: "0x%llx", entrypoint.routine)]
            if let parameter = entrypoint.parameter {
                ep["parameter"] = String(format: "0x%llx", parameter)
            }
            obj["entrypoint"] = ep
        }
        return obj
    }

    // MARK: - list_session_instruments

    private static func registerListSessionInstruments(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_session_instruments",
            description: "List all instruments currently attached to a session: tracer hooks, custom instrument instances, hookpacks, and codeshare snippets. Returns id, kind, source_identifier, state (enabled/disabled), attachment (attached/detached), status (present when the instance failed to load/reload/validate), and component_statuses (per-hook compile failures on tracer instances). Use to understand what's already running and whether anything is in error before adding more.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            let instances = engine.instrumentsBySession[sessionID] ?? []
            let node = engine.node(forSessionID: sessionID)
            let array: [[String: Any]] = instances.map { instance in
                instanceListEntry(instance, ref: node?.instruments.first(where: { $0.id == instance.id }))
            }
            return makeResult(jsonObject: array, summary: "\(array.count) instrument\(array.count == 1 ? "" : "s") attached")
        }
    }

    private static func instanceListEntry(_ instance: InstrumentInstance, ref: ProcessNode.InstrumentRef?) -> [String: Any] {
        var entry: [String: Any] = [
            "id": instance.id.uuidString,
            "kind": instance.kind.rawValue,
            "source_identifier": instance.sourceIdentifier,
            "state": instance.state.rawValue,
            "attachment": ref?.attachment.rawValue ?? "detached",
        ]
        if let status = ref?.status {
            entry["status"] = status.toWireJSON()
        }
        if let statuses = ref?.componentStatuses, !statuses.isEmpty {
            entry["component_statuses"] = statuses.map { (id, status) -> [String: Any] in
                var obj = status.toWireJSON()
                obj["component_id"] = id.uuidString
                return obj
            }
        }
        return entry
    }

    // MARK: - arm_session / disarm_session

    private static func registerArmSession(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "arm_session",
            description: "Arm spawn-gating on the session's device with the given match pattern (glob over identifiers / process names). Newly-spawned processes that match get held for inspection until the session resumes them. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"match_pattern":{"type":"string","description":"Glob matched against new process identifiers / names"}},"required":["session_id","match_pattern"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let pattern = invocation.args["match_pattern"] as? String, !pattern.isEmpty else {
                return errorResult("missing match_pattern", code: .invalidInput)
            }
            guard engine.sessions.contains(where: { $0.id == sessionID }) else {
                return errorResult("no session with id \(sessionID)", code: .notFound)
            }
            await engine.armSession(id: sessionID, matchPattern: pattern)
            let payload: [String: Any] = ["session_id": sessionID.uuidString, "match_pattern": pattern]
            return makeResult(jsonObject: payload, summary: "Armed session with pattern \(pattern)")
        }
    }

    private static func registerDisarmSession(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "disarm_session",
            description: "Stop spawn-gating on the session's device.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard engine.sessions.contains(where: { $0.id == sessionID }) else {
                return errorResult("no session with id \(sessionID)", code: .notFound)
            }
            await engine.disarmSession(id: sessionID)
            let payload: [String: Any] = ["session_id": sessionID.uuidString]
            return makeResult(jsonObject: payload, summary: "Disarmed session")
        }
    }

    private static func registerResumeSession(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "resume_session",
            description: "Resume a session held after a gated-spawn attach (phase = awaiting_initial_resume). Use after arm_session captures the target and you've installed any hooks; the target process actually starts running. No-op if the session is already running.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)", code: .notFound)
            }
            await engine.resumeSpawnedProcess(node: node)
            let payload: [String: Any] = ["session_id": sessionID.uuidString]
            return makeResult(jsonObject: payload, summary: "Resumed session")
        }
    }

    // MARK: - summarize_recent_events

    private static func registerSummarizeRecentEvents(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "summarize_recent_events",
            description: "Read the most recent runtime events from the global event log. Filter by session_id, kind (substring on the event kind name), or match_pattern (case-insensitive regex on the event summary). Pass since_event_id to only get events newer than a previously-seen id. Each event includes a compact structured 'payload' field using $type-tagged JS values (NativePointer / BigInt / Date / RegExp / Uint8Array / Function / Error / Map / Set / Truncated / ref). Tracer events are decoded into named fields with caller and backtrace pre-symbolicated as $type:Symbol references. Pass include_payload=false to omit payloads, or symbolicate=false to keep tracer addresses as raw NativePointer.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"kind":{"type":"string","description":"Filter by event kind, e.g. tracer, repl"},"match_pattern":{"type":"string","description":"Case-insensitive regex matched against the event summary."},"since_event_id":{"type":"string","description":"Only return events that arrived after this id."},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Max events to return (default 50)"},"include_payload":{"type":"boolean","description":"Include each event's structured payload (default true, capped to a compact depth)."},"symbolicate":{"type":"boolean","description":"For tracer events, symbolicate caller and backtrace addresses (default true)."}},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let limit = (invocation.args["limit"] as? Int) ?? 50
            do {
                let request = try parseEventListingRequest(invocation.args, defaultDetail: .compact)
                let matched = filteredEvents(engine.eventLog.events, filter: request.filter)
                let returned = Array(matched.suffix(limit))
                return await eventListingResult(returned, totalConsidered: matched.count, options: request.options, engine: engine)
            } catch let error as EventFilterError {
                return errorResult(error.message, code: .invalidInput)
            } catch {
                return errorResult("filter failed: \(error.localizedDescription)")
            }
        }
    }

    private static func registerWaitForEvent(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "wait_for_event",
            description: "Block until at least one matching runtime event arrives, or the timeout elapses. Same filter and payload shape as summarize_recent_events. Pair it with a hook install or a user-driven trigger so the agent doesn't need to poll. Returns matching events newer than since_event_id, or an empty list on timeout.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"kind":{"type":"string"},"match_pattern":{"type":"string"},"since_event_id":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Max events to return (default 50)"},"timeout_ms":{"type":"integer","minimum":100,"maximum":60000,"description":"Maximum wait in milliseconds (default 30000, capped at 60000)"},"include_payload":{"type":"boolean"},"symbolicate":{"type":"boolean"}},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let limit = (invocation.args["limit"] as? Int) ?? 50
            let timeoutMs = min((invocation.args["timeout_ms"] as? Int) ?? 30_000, 60_000)
            let request: EventListingRequest
            do {
                request = try parseEventListingRequest(invocation.args, defaultDetail: .compact)
            } catch let error as EventFilterError {
                return errorResult(error.message, code: .invalidInput)
            } catch {
                return errorResult("filter failed: \(error.localizedDescription)")
            }

            let pollIntervalNs: UInt64 = 100_000_000
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            while true {
                try? Task.checkCancellation()
                let matched = filteredEvents(engine.eventLog.events, filter: request.filter)
                if !matched.isEmpty {
                    let returned = Array(matched.suffix(limit))
                    return await eventListingResult(returned, totalConsidered: matched.count, options: request.options, engine: engine)
                }
                if Date() >= deadline {
                    return await eventListingResult([], totalConsidered: 0, options: request.options, engine: engine, summary: "No matching events within \(timeoutMs)ms")
                }
                try? await Task.sleep(nanoseconds: pollIntervalNs)
            }
        }
    }

    // MARK: - read_event

    private static func registerReadEvent(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_event",
            description: "Read a single runtime event by id, returning its full structured payload (uncapped depth). Tracer events are decoded into named fields with caller and backtrace pre-symbolicated as $type:Symbol references. The event log is a bounded ring buffer, so older ids may have been evicted; in that case the tool returns not-found.",
            inputSchemaJSON: """
                {"type":"object","properties":{"event_id":{"type":"string"},"symbolicate":{"type":"boolean","description":"For tracer events, symbolicate caller and backtrace addresses (default true)."}},"required":["event_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let raw = invocation.args["event_id"] as? String, let eventID = UUID(uuidString: raw) else {
                return errorResult("missing or invalid event_id", code: .invalidInput)
            }
            guard let event = engine.eventLog.events.first(where: { $0.id == eventID }) else {
                return errorResult("no event with id \(eventID); the ring buffer may have evicted it", code: .notFound)
            }
            let symbolicate = (invocation.args["symbolicate"] as? Bool) ?? true
            let options = EventListingOptions(payloadDetail: .full, symbolicateAddresses: symbolicate)
            let symbols = await collectSymbolLookup(in: [event], options: options, engine: engine)
            let obj = renderEventJSON(event, options: options, symbols: symbols)
            return makeResult(jsonObject: obj, summary: "Event \(eventID.uuidString) (\(describeEventKind(event)))")
        }
    }

    private struct EventListingRequest {
        let filter: EventFilter
        let options: EventListingOptions
    }

    private struct EventListingOptions {
        enum PayloadDetail {
            case omit
            case compact
            case full

            var jsonOptions: JSInspectValue.AgentJSONOptions? {
                switch self {
                case .omit: return nil
                case .compact: return .compact
                case .full: return .full
                }
            }
        }

        let payloadDetail: PayloadDetail
        let symbolicateAddresses: Bool
    }

    private struct EventFilter {
        var sessionID: UUID?
        var kindSubstring: String?
        var pattern: Regex<AnyRegexOutput>?
        var sinceEventID: UUID?
    }

    private struct EventFilterError: Swift.Error {
        let message: String
    }

    private static func parseEventListingRequest(_ args: [String: Any], defaultDetail: EventListingOptions.PayloadDetail) throws -> EventListingRequest {
        let filter = try parseEventFilter(args)
        let includePayload = (args["include_payload"] as? Bool) ?? true
        let symbolicate = (args["symbolicate"] as? Bool) ?? true
        let options = EventListingOptions(
            payloadDetail: includePayload ? defaultDetail : .omit,
            symbolicateAddresses: symbolicate
        )
        return EventListingRequest(filter: filter, options: options)
    }

    private static func parseEventFilter(_ args: [String: Any]) throws -> EventFilter {
        var filter = EventFilter()
        filter.sessionID = parseSessionID(args)
        if let kind = args["kind"] as? String, !kind.isEmpty {
            filter.kindSubstring = kind
        }
        if let raw = (args["match_pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            do {
                filter.pattern = try Regex(raw).ignoresCase()
            } catch {
                throw EventFilterError(message: "invalid match_pattern: \(error.localizedDescription)")
            }
        }
        if let sinceRaw = args["since_event_id"] as? String, !sinceRaw.isEmpty {
            guard let id = UUID(uuidString: sinceRaw) else {
                throw EventFilterError(message: "invalid since_event_id")
            }
            filter.sinceEventID = id
        }
        return filter
    }

    private static func filteredEvents(_ events: [RuntimeEvent], filter: EventFilter) -> [RuntimeEvent] {
        var slice = events[...]
        if let since = filter.sinceEventID, let cut = slice.firstIndex(where: { $0.id == since }) {
            slice = slice[slice.index(after: cut)...]
        }
        return slice.filter { event in
            if let id = filter.sessionID, event.sessionID != id { return false }
            if let kind = filter.kindSubstring, !describeEventKind(event).contains(kind) { return false }
            if let pattern = filter.pattern, !describeEventSummary(event).contains(pattern) { return false }
            return true
        }
    }

    private static func eventListingResult(
        _ events: [RuntimeEvent],
        totalConsidered: Int,
        options: EventListingOptions,
        engine: Engine,
        summary: String? = nil
    ) async -> ActionResult {
        let symbols = await collectSymbolLookup(in: events, options: options, engine: engine)
        let array = events.map { renderEventJSON($0, options: options, symbols: symbols) }
        let resolvedSummary = summary ?? "Returned \(events.count) of \(totalConsidered) matching event\(totalConsidered == 1 ? "" : "s")"
        return makeResult(jsonObject: array, summary: resolvedSummary)
    }

    private static func collectSymbolLookup(in events: [RuntimeEvent], options: EventListingOptions, engine: Engine) async -> SymbolLookup {
        guard options.symbolicateAddresses else { return SymbolLookup() }

        var addressesBySession: [UUID: Set<UInt64>] = [:]
        for event in events {
            guard let sid = event.sessionID, isTracerEvent(event) else { continue }
            guard case .jsValue(let value) = event.payload,
                let tracer = Engine.parseTracerEvent(from: value)
            else { continue }
            var addresses = addressesBySession[sid] ?? []
            if let address = tracer.caller.nativePointerAddress {
                addresses.insert(address)
            }
            for pointer in tracer.backtrace ?? [] {
                if let address = pointer.nativePointerAddress {
                    addresses.insert(address)
                }
            }
            addressesBySession[sid] = addresses
        }

        var bySession: [UUID: [UInt64: SymbolDisplay]] = [:]
        for (sessionID, addressSet) in addressesBySession where !addressSet.isEmpty {
            let addresses = Array(addressSet)
            let displays = await engine.symbolDisplay(sessionID: sessionID, addresses: addresses)
            var map: [UInt64: SymbolDisplay] = [:]
            for (idx, display) in displays.enumerated() where idx < addresses.count {
                map[addresses[idx]] = display
            }
            bySession[sessionID] = map
        }

        return SymbolLookup(bySession: bySession)
    }

    private struct SymbolLookup {
        private let bySession: [UUID: [UInt64: SymbolDisplay]]

        init(bySession: [UUID: [UInt64: SymbolDisplay]] = [:]) {
            self.bySession = bySession
        }

        func symbol(for address: UInt64, sessionID: UUID) -> SymbolDisplay? {
            bySession[sessionID]?[address]
        }
    }

    private static func renderEventJSON(_ event: RuntimeEvent, options: EventListingOptions, symbols: SymbolLookup) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var obj: [String: Any] = [
            "id": event.id.uuidString,
            "kind": describeEventKind(event),
            "timestamp": formatter.string(from: event.timestamp),
            "summary": describeEventSummary(event),
        ]
        if let sid = event.sessionID { obj["session_id"] = sid.uuidString }
        if let jsonOptions = options.payloadDetail.jsonOptions,
            let payload = renderEventPayload(event, jsonOptions: jsonOptions, symbols: symbols) {
            obj["payload"] = payload
        }
        return obj
    }

    private static func renderEventPayload(_ event: RuntimeEvent, jsonOptions: JSInspectValue.AgentJSONOptions, symbols: SymbolLookup) -> Any? {
        switch event.payload {
        case .consoleMessage(let msg):
            return [
                "$type": "ConsoleMessage",
                "level": msg.level.rawValue,
                "values": msg.values.map { $0.toAgentJSON(options: jsonOptions) },
            ] as [String: Any]
        case .jsError(let err):
            return jsErrorPayload(err, jsonOptions: jsonOptions)
        case .jsValue(let value):
            if isTracerEvent(event),
                let decoded = decodeTracerPayload(value, sessionID: event.sessionID, jsonOptions: jsonOptions, symbols: symbols) {
                return decoded
            }
            return value.toAgentJSON(options: jsonOptions)
        case .raw:
            return nil
        }
    }

    private static func isTracerEvent(_ event: RuntimeEvent) -> Bool {
        if case .instrument(_, let name) = event.source, name == "tracer" { return true }
        return false
    }

    private static func decodeTracerPayload(
        _ value: JSInspectValue,
        sessionID: UUID?,
        jsonOptions: JSInspectValue.AgentJSONOptions,
        symbols: SymbolLookup
    ) -> [String: Any]? {
        guard let tracer = Engine.parseTracerEvent(from: value) else { return nil }
        var obj: [String: Any] = [
            "$type": "TracerEvent",
            "hook_id": tracer.id.uuidString,
            "timestamp_ms": tracer.timestamp,
            "thread_id": tracer.threadId,
            "depth": tracer.depth,
            "caller": symbolReferenceJSON(for: tracer.caller, sessionID: sessionID, symbols: symbols),
            "message": tracer.message.toAgentJSON(options: jsonOptions),
        ]
        if let backtrace = tracer.backtrace {
            obj["backtrace"] = backtrace.map { symbolReferenceJSON(for: $0, sessionID: sessionID, symbols: symbols) }
        }
        return obj
    }

    private static func symbolReferenceJSON(for pointer: JSInspectValue, sessionID: UUID?, symbols: SymbolLookup) -> Any {
        guard case .nativePointer(let raw) = pointer else {
            return pointer.toAgentJSON(options: .compact)
        }
        guard let sid = sessionID,
            let address = pointer.nativePointerAddress,
            let display = symbols.symbol(for: address, sessionID: sid),
            display.raw != nil || display.overlay != nil
        else {
            return ["$type": "NativePointer", "value": raw] as [String: Any]
        }
        return symbolJSON(display, address: raw)
    }

    private static func symbolJSON(_ display: SymbolDisplay, address: String) -> [String: Any] {
        var obj: [String: Any] = [
            "$type": "Symbol",
            "address": address,
            "name": display.primary,
        ]
        if let raw = display.raw {
            obj["module"] = raw.module
            obj["raw_name"] = raw.name
            if let offset = raw.offset {
                obj["raw_offset"] = offset
            }
        }
        if let overlay = display.overlay {
            obj["insight_name"] = overlay.title
            if overlay.offset != 0 {
                obj["insight_offset"] = overlay.offset
            }
        }
        if let source = display.source {
            obj["file"] = source.file
            obj["line"] = source.line
            if let column = source.column {
                obj["column"] = column
            }
        }
        return obj
    }

    private static func jsErrorPayload(_ err: JSError, jsonOptions: JSInspectValue.AgentJSONOptions) -> [String: Any] {
        var dict: [String: Any] = [
            "$type": "Error",
            "message": err.text,
        ]
        if let fileName = err.fileName {
            dict["file"] = fileName
        }
        if let lineNumber = err.lineNumber {
            dict["line"] = lineNumber
        }
        if let columnNumber = err.columnNumber {
            dict["column"] = columnNumber
        }
        if let stack = err.stack, !stack.isEmpty {
            dict["stack"] = stack
        }
        return dict
    }

    // MARK: - resolve_symbol

    private static func registerResolveSymbol(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "resolve_symbol",
            description: "Resolve a symbol query to one or more addresses. Queries support globbing (e.g. '*Keychain*'). 'function' searches module exports; 'objc-method' / 'swift-func' / 'java-method' / 'debug-symbol' search those runtimes (Java requires the frida-java-bridge package — install via install_package). 'absolute-instruction' just packages a hex address as an instruction anchor; 'relative-function' takes 'MODULE!OFFSET'.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"scope":{"type":"string","enum":["function","module","imports","relative-function","absolute-instruction","objc-method","swift-func","java-method","debug-symbol"]},"query":{"type":"string"}},"required":["session_id","scope","query"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)", code: .notFound)
            }
            guard let scope = invocation.args["scope"] as? String,
                let query = invocation.args["query"] as? String
            else {
                return errorResult("missing scope or query", code: .invalidInput)
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
            description: "Disassemble instructions starting at the given address. Returns plain-text assembly with addresses and bytes. Use after resolve_symbol to look at a function's body. The 'scope' field is 'function' when the address is a known function start (output covers the whole function, may be shorter than count) or 'span' otherwise (output is exactly count instructions from the address).",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address, e.g. 0x1004500"},"count":{"type":"integer","minimum":1,"maximum":256,"default":32}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            let count = (invocation.args["count"] as? Int) ?? 32
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            guard engine.node(forSessionID: sessionID) != nil else {
                return errorResult("no attached session for id \(sessionID)", code: .notFound)
            }
            let page = await dis.disassemblePage(DisassemblyRequest(address: address, count: count, appearance: .light))
            let text: String = page.lines.map { (line: DisassemblyLine) -> String in
                let addr: String = String(format: "0x%llx", line.address)
                let asm: String = line.asmText.plainText
                let comment: String = line.commentText?.plainText ?? ""
                let suffix: String = comment.isEmpty ? "" : "  \(comment)"
                return "\(addr)  \(asm)\(suffix)"
            }.joined(separator: "\n")
            let scopeLabel: String
            switch page.scope {
            case .function: scopeLabel = "function"
            case .span: scopeLabel = "span"
            }
            let payload: [String: Any] = [
                "address": addrString,
                "count": page.lines.count,
                "scope": scopeLabel,
                "text": text,
            ]
            return makeResult(jsonObject: payload, summary: "Disassembled \(page.lines.count) instruction\(page.lines.count == 1 ? "" : "s") at \(addrString)")
        }
    }

    // MARK: - read_memory

    private static func registerReadMemory(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_memory",
            description: "Read up to 4096 bytes of process memory. 'format' picks the response shape: 'hex' (space-separated hex bytes, default), 'utf8' (decoded string up to the first invalid sequence), or 'cstring' (NUL-terminated C string, count is the maximum scan length). Use the narrowest format that answers your question — large hex dumps burn tokens.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address"},"count":{"type":"integer","minimum":1,"maximum":4096,"default":256},"format":{"type":"string","enum":["hex","utf8","cstring"],"default":"hex"}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            let count = min((invocation.args["count"] as? Int) ?? 256, 4096)
            let format = (invocation.args["format"] as? String) ?? "hex"
            guard ["hex", "utf8", "cstring"].contains(format) else {
                return errorResult("format must be one of hex, utf8, cstring", code: .invalidInput)
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)", code: .notFound)
            }
            do {
                let bytes = try await node.readRemoteMemory(at: address, count: count)
                var payload: [String: Any] = [
                    "address": addrString,
                    "count": bytes.count,
                    "format": format,
                ]
                switch format {
                case "hex":
                    payload["hex"] = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                case "utf8":
                    payload["string"] = String(bytes: bytes, encoding: .utf8) as Any? ?? NSNull()
                case "cstring":
                    let nulIndex = bytes.firstIndex(of: 0) ?? bytes.endIndex
                    payload["string"] = String(bytes: bytes[..<nulIndex], encoding: .utf8) as Any? ?? NSNull()
                default:
                    break
                }
                return makeResult(jsonObject: payload, summary: "Read \(bytes.count) bytes at \(addrString)")
            } catch {
                return errorResult("memory read failed: \(error.localizedDescription)", code: .failed)
            }
        }
    }

    private static func registerWriteMemory(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "write_memory",
            description: "Write up to 4096 bytes to process memory. Pass 'bytes' as a hex string (e.g. 'deadbeef'). Returns the number of bytes written. Requires user approval; only use when you've justified the patch in a finding.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address"},"bytes":{"type":"string","description":"Hex string of bytes to write (no 0x prefix, no spaces, even length)"}},"required":["session_id","address","bytes"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            guard let hexString = invocation.args["bytes"] as? String,
                let bytes = parseHexBytes(hexString),
                !bytes.isEmpty,
                bytes.count <= 4096
            else {
                return errorResult("bytes must be a non-empty even-length hex string up to 8192 chars", code: .invalidInput)
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)", code: .notFound)
            }
            do {
                try await node.writeRemoteMemory(at: address, bytes: bytes)
                let payload: [String: Any] = [
                    "address": addrString,
                    "count": bytes.count,
                ]
                return makeResult(jsonObject: payload, summary: "Wrote \(bytes.count) bytes at \(addrString)")
            } catch {
                return errorResult("memory write failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - notebook

    private static func registerListNotebookEntries(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_notebook_entries",
            description: "List notebook entries in this project. Returns id, kind (note or capture), title, a short details preview, and optional session/process attribution. Use read_notebook_entry to fetch full bodies.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let array = engine.notebookEntries.map(notebookListEntry)
            return makeResult(jsonObject: array, summary: "\(array.count) notebook entr\(array.count == 1 ? "y" : "ies")")
        }
    }

    private static func registerReadNotebookEntry(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_notebook_entry",
            description: "Read a notebook entry's full body, including the complete details text.",
            inputSchemaJSON: """
                {"type":"object","properties":{"entry_id":{"type":"string"}},"required":["entry_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let entryID = (invocation.args["entry_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid entry_id", code: .invalidInput)
            }
            guard let entry = engine.notebookEntries.first(where: { $0.id == entryID }) else {
                return errorResult("no notebook entry with id \(entryID)", code: .notFound)
            }
            var payload = notebookListEntry(entry)
            payload["details"] = entry.details
            return makeResult(jsonObject: payload, summary: "Notebook entry: \(entry.title)")
        }
    }

    private static func registerCreateNotebookEntry(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "create_notebook_entry",
            description: "Create a notebook entry. 'kind' defaults to 'note' (a freeform note). Use 'capture' when the body comes from a target observation. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"title":{"type":"string"},"details":{"type":"string"},"kind":{"type":"string","enum":["note","capture"],"default":"note"},"session_id":{"type":"string"}},"required":["title","details"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let title = invocation.args["title"] as? String, !title.isEmpty else {
                return errorResult("missing title", code: .invalidInput)
            }
            guard let details = invocation.args["details"] as? String else {
                return errorResult("missing details", code: .invalidInput)
            }
            let kind: NotebookEntry.Kind = ((invocation.args["kind"] as? String) == "capture") ? .capture : .note
            let sessionID = (invocation.args["session_id"] as? String).flatMap(UUID.init(uuidString:))
            let processName = sessionID.flatMap { id in engine.sessions.first(where: { $0.id == id })?.processName }
            let entry = NotebookEntry(
                kind: kind,
                title: title,
                details: details,
                sessionID: sessionID,
                processName: processName
            )
            engine.addNotebookEntry(entry)
            return makeResult(jsonObject: ["entry_id": entry.id.uuidString, "title": entry.title], summary: "Created notebook entry: \(entry.title)")
        }
    }

    private static func registerUpdateNotebookEntry(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "update_notebook_entry",
            description: "Update a notebook entry's title, details, or kind. Only fields you pass change. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"entry_id":{"type":"string"},"title":{"type":"string"},"details":{"type":"string"},"kind":{"type":"string","enum":["note","capture"]}},"required":["entry_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let entryID = (invocation.args["entry_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid entry_id", code: .invalidInput)
            }
            guard var entry = engine.notebookEntries.first(where: { $0.id == entryID }) else {
                return errorResult("no notebook entry with id \(entryID)", code: .notFound)
            }
            if let title = invocation.args["title"] as? String, !title.isEmpty {
                entry.title = title
            }
            if let details = invocation.args["details"] as? String {
                entry.details = details
            }
            if let kindRaw = invocation.args["kind"] as? String {
                entry.kind = (kindRaw == "capture") ? .capture : .note
            }
            engine.updateNotebookEntry(entry)
            return makeResult(jsonObject: ["entry_id": entry.id.uuidString, "title": entry.title], summary: "Updated notebook entry: \(entry.title)")
        }
    }

    private static func registerDeleteNotebookEntry(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "delete_notebook_entry",
            description: "Delete a notebook entry. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"entry_id":{"type":"string"}},"required":["entry_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let entryID = (invocation.args["entry_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid entry_id", code: .invalidInput)
            }
            guard let entry = engine.notebookEntries.first(where: { $0.id == entryID }) else {
                return errorResult("no notebook entry with id \(entryID)", code: .notFound)
            }
            engine.deleteNotebookEntry(entry)
            return makeResult(jsonObject: ["entry_id": entryID.uuidString, "removed": true], summary: "Deleted notebook entry: \(entry.title)")
        }
    }

    private static func notebookListEntry(_ entry: NotebookEntry) -> [String: Any] {
        var payload: [String: Any] = [
            "entry_id": entry.id.uuidString,
            "kind": entry.kind.rawValue,
            "title": entry.title,
            "preview": String(entry.details.prefix(200)),
            "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
        ]
        if let sessionID = entry.sessionID {
            payload["session_id"] = sessionID.uuidString
        }
        if let processName = entry.processName {
            payload["process_name"] = processName
        }
        return payload
    }

    // MARK: - eval_repl (act)

    private static func registerEvalREPL(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "eval_repl",
            description: "Run a one-off JavaScript snippet in the target process via Frida's REPL and return its value inline. The result is `{cell_id, code, kind, value?, text?}` where kind is 'value' (JS expression result, `value` is the $type-tagged structured encoding used elsewhere) or 'text' (pipeline output or error message in `text`). Requires user approval — `intent` is shown to the approver and recorded in the audit log, so write a sentence that makes the why obvious.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"code":{"type":"string"},"intent":{"type":"string","description":"One sentence shown to the approver explaining why you're running this; logged with the action."}},"required":["session_id","code","intent"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true,
            codePreview: CodePreviewArg(field: "code", language: .fridaJavaScript)
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let code = invocation.args["code"] as? String, !code.isEmpty else {
                return errorResult("missing code", code: .invalidInput)
            }
            guard let node = engine.node(forSessionID: sessionID) else {
                return errorResult("no attached session for id \(sessionID)", code: .notFound)
            }
            let cellID = UUID()
            guard let result = await node.evalInREPL(code, cellID: cellID) else {
                return errorResult("REPL evaluation produced no result", code: .unavailable)
            }
            return evalREPLResult(result)
        }
    }

    private static func evalREPLResult(_ result: REPLResult) -> ActionResult {
        let cellShort = result.id.uuidString.prefix(8)
        var payload: [String: Any] = [
            "cell_id": result.id.uuidString,
            "code": result.code,
        ]
        let summary: String
        switch result.value {
        case .js(let value):
            payload["kind"] = "value"
            payload["value"] = value.toAgentJSON(options: .compact)
            summary = "REPL cell \(cellShort) → \(value.agentSummary())"
        case .text(let text):
            payload["kind"] = "text"
            payload["text"] = text
            let preview = text.count > 96 ? text.prefix(95) + "…" : Substring(text)
            summary = "REPL cell \(cellShort) → \(preview)"
        case .styled(let styled):
            let text = styled.plainText
            payload["kind"] = "text"
            payload["text"] = text
            let preview = text.count > 96 ? text.prefix(95) + "…" : Substring(text)
            summary = "REPL cell \(cellShort) → \(preview)"
        case .binary(let data, _):
            payload["kind"] = "binary"
            payload["byte_count"] = data.count
            summary = "REPL cell \(cellShort) → \(data.count) bytes"
        }
        return makeResult(jsonObject: payload, summary: summary)
    }

    // MARK: - install_tracer_hook (act)

    private static func registerInstallTracerHook(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "install_tracer_hook",
            description: "Install a tracer hook. 'target' is either a hex address or a query for the chosen 'scope' (function / objc-method / swift-func / java-method / debug-symbol). 'kind' controls when the hook fires: 'function' on entry/exit, 'instruction' on a single instruction. Pass 'code' to start with custom JS in one shot; omit to install the default stub. The hook is enabled on install. If a hook already exists at the same anchor, the existing hook is returned unchanged — use update_tracer_hook to modify it. For Java, install_package frida-java-bridge first.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"target":{"type":"string","description":"Hex address (0x...) or symbol query for the chosen scope"},"scope":{"type":"string","enum":["function","objc-method","swift-func","java-method","debug-symbol"],"default":"function","description":"Resolver to use when target isn't a hex address. Ignored when target is hex."},"kind":{"type":"string","enum":["function","instruction"],"default":"function"},"code":{"type":"string","description":"Custom JS handler. Omit to use the default stub for this hook kind."}},"required":["session_id","target"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true,
            codePreview: CodePreviewArg(field: "code", language: .fridaTypeScript)
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let target = invocation.args["target"] as? String, !target.isEmpty else {
                return errorResult("missing target", code: .invalidInput)
            }
            let kindString = (invocation.args["kind"] as? String) ?? "function"
            let kind: TracerHookKind = kindString == "instruction" ? .instruction : .function
            let code = (invocation.args["code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let scope = (invocation.args["scope"] as? String) ?? "function"

            let address: UInt64
            var preferredAnchor: AddressAnchor?
            var preferredDisplayName: String?
            if let parsed = parseHexAddress(target) {
                address = parsed
            } else {
                guard let node = engine.node(forSessionID: sessionID) else {
                    return errorResult("no attached session for id \(sessionID)", code: .notFound)
                }
                do {
                    let resolved = try await node.resolveTargets(scope: scope, query: target)
                    guard let first = resolved.first,
                        let addrStr = first["address"] as? String,
                        let parsed = parseHexAddress(addrStr)
                    else {
                        return errorResult("could not resolve target '\(target)' under scope '\(scope)'", code: .notFound)
                    }
                    address = parsed
                    preferredAnchor = decodeAnchorJSON(first["anchor"] as? [String: Any])
                    preferredDisplayName = first["displayName"] as? String
                } catch {
                    return errorResult("resolve failed: \(error.localizedDescription)")
                }
            }

            guard let result = await engine.addTracerHook(
                sessionID: sessionID,
                address: address,
                kind: kind,
                code: code,
                preferredAnchor: preferredAnchor,
                preferredDisplayName: preferredDisplayName
            ) else {
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

    private static func decodeAnchorJSON(_ obj: [String: Any]?) -> AddressAnchor? {
        guard let obj, let type = obj["type"] as? String else { return nil }
        switch type {
        case "absolute":
            guard let addrStr = obj["address"] as? String, let addr = parseHexAddress(addrStr) else { return nil }
            return .absolute(addr)
        case "moduleOffset":
            guard let name = obj["name"] as? String, let offset = obj["offset"] as? Int else { return nil }
            return .moduleOffset(name: name, offset: UInt64(offset))
        case "moduleExport":
            guard let name = obj["name"] as? String, let export = obj["export"] as? String else { return nil }
            return .moduleExport(name: name, export: export)
        case "objcMethod":
            guard let selector = obj["selector"] as? String else { return nil }
            return .objcMethod(selector: selector)
        case "swiftFunc":
            guard let module = obj["module"] as? String, let function = obj["function"] as? String else { return nil }
            return .swiftFunc(module: module, function: function)
        case "javaMethod":
            guard let className = obj["className"] as? String, let methodName = obj["methodName"] as? String else { return nil }
            return .javaMethod(className: className, methodName: methodName)
        case "debugSymbol":
            guard let name = obj["name"] as? String else { return nil }
            return .debugSymbol(name: name)
        default:
            return nil
        }
    }

    private static func registerListTracerHooks(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_tracer_hooks",
            description: "List tracer hooks installed on the session. Returns metadata only (id, target, kind, state, itrace) plus `compile_error` on any hook whose JS failed to compile. Fetch the JS body via read_tracer_hook when you need it.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let hooks = engine.tracerHooks(forSessionID: sessionID) else {
                return makeResult(jsonObject: [], summary: "No tracer instrument on this session")
            }
            let array: [[String: Any]] = hooks.map { hook in
                var entry = hookListEntry(hook)
                if let err = tracerHookComponentStatus(engine: engine, sessionID: sessionID, hookID: hook.id) {
                    entry["compile_error"] = err
                }
                return entry
            }
            return makeResult(jsonObject: array, summary: "\(hooks.count) tracer hook\(hooks.count == 1 ? "" : "s")")
        }
    }

    private static func registerReadTracerHook(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_tracer_hook",
            description: "Read a tracer hook's full body, including its JS handler code. The `code` field is line-numbered (1-based, `<lineno>\\t<text>\\n`); strip the prefix before reuse. `line_count` is also returned. Use this only when you intend to read or edit the code; list_tracer_hooks is cheaper for surveying hooks.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"hook_id":{"type":"string"}},"required":["session_id","hook_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let hookID = (invocation.args["hook_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid hook_id", code: .invalidInput)
            }
            guard let hook = engine.tracerHook(sessionID: sessionID, hookID: hookID) else {
                return errorResult("no tracer hook with id \(hookID)", code: .notFound)
            }
            var payload = hookListEntry(hook)
            payload["code"] = numberedContent(hook.code)
            payload["line_count"] = lineCount(of: hook.code)
            if let err = tracerHookComponentStatus(engine: engine, sessionID: sessionID, hookID: hookID) {
                payload["compile_error"] = err
            }
            return makeResult(jsonObject: payload, summary: "Hook \(hook.displayName)")
        }
    }

    private static func registerUpdateTracerHook(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "update_tracer_hook",
            description: "Update one or more fields of a tracer hook. Only fields you pass change. Pass 'code' to swap the JS handler. Pass 'state' (\"enabled\" or \"disabled\") to toggle the hook. Pass 'itrace_arming' to arm instruction tracing for this hook with safety caps (max_invocations stops new captures once it's reached; max_bytes_per_invocation auto-stops a single capture once it crosses that many bytes). Pass null to disarm.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"hook_id":{"type":"string"},"code":{"type":"string"},"display_name":{"type":"string"},"state":{"type":"string","enum":["enabled","disabled"]},"itrace_arming":{"type":["object","null"],"properties":{"max_invocations":{"type":"integer","minimum":1,"default":5},"max_bytes_per_invocation":{"type":"integer","minimum":1024,"default":1000000}},"additionalProperties":false}},"required":["session_id","hook_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true,
            codePreview: CodePreviewArg(field: "code", language: .fridaTypeScript)
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let hookID = (invocation.args["hook_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid hook_id", code: .invalidInput)
            }
            let code = invocation.args["code"] as? String
            let displayName = invocation.args["display_name"] as? String
            let state = (invocation.args["state"] as? String).flatMap(TracerConfig.Hook.State.init(rawValue:))
            let armingArg = invocation.args["itrace_arming"]

            guard let updated = await engine.updateTracerHook(sessionID: sessionID, hookID: hookID, { hook in
                if let code { hook.updateCode(code) }
                if let displayName { hook.displayName = displayName }
                if let state { hook.state = state }
                if armingArg is NSNull {
                    hook.itraceArming = nil
                } else if let armingObj = armingArg as? [String: Any] {
                    let maxInvocations = (armingObj["max_invocations"] as? Int) ?? ITraceArming.defaultMaxInvocations
                    let maxBytes = (armingObj["max_bytes_per_invocation"] as? Int) ?? ITraceArming.defaultMaxBytesPerInvocation
                    hook.itraceArming = ITraceArming(maxInvocations: maxInvocations, maxBytesPerInvocation: maxBytes)
                }
            }) else {
                return errorResult("no tracer hook with id \(hookID)", code: .notFound)
            }
            return tracerHookEditResult(engine: engine, sessionID: sessionID, hook: updated, summaryPrefix: "Updated hook \(updated.displayName)")
        }
    }

    private static func registerEditTracerHook(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "edit_tracer_hook",
            description: """
                Replace a contiguous range of lines in a tracer hook's JS handler. Lines are 1-based and inclusive; \
                `start_line` is the first line replaced and `end_line` is the last. To insert without replacing, pass \
                `end_line = start_line - 1`; to append, use `start_line = line_count + 1, end_line = line_count`. \
                `new_content` may span multiple lines and does not need a trailing newline. Prefer this over \
                update_tracer_hook's `code` field for targeted edits.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"hook_id":{"type":"string"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":0},"new_content":{"type":"string"}},"required":["session_id","hook_id","start_line","end_line","new_content"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true,
            codePreview: CodePreviewArg(field: "new_content", language: .fridaTypeScript)
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let hookID = (invocation.args["hook_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid hook_id", code: .invalidInput)
            }
            guard let startLine = invocation.args["start_line"] as? Int else {
                return errorResult("missing or invalid start_line", code: .invalidInput)
            }
            guard let endLine = invocation.args["end_line"] as? Int else {
                return errorResult("missing or invalid end_line", code: .invalidInput)
            }
            guard let newContent = invocation.args["new_content"] as? String else {
                return errorResult("missing new_content", code: .invalidInput)
            }
            guard let existing = engine.tracerHook(sessionID: sessionID, hookID: hookID) else {
                return errorResult("no tracer hook with id \(hookID)", code: .notFound)
            }
            let updatedCode: String
            switch spliceLines(in: existing.code, startLine: startLine, endLine: endLine, replacement: newContent) {
            case .success(let result):
                updatedCode = result
            case .failure(let message):
                return errorResult(message, code: .invalidInput)
            }
            guard let updated = await engine.updateTracerHook(sessionID: sessionID, hookID: hookID, { hook in
                hook.updateCode(updatedCode)
            }) else {
                return errorResult("no tracer hook with id \(hookID)", code: .notFound)
            }
            return tracerHookEditResult(
                engine: engine,
                sessionID: sessionID,
                hook: updated,
                summaryPrefix: "Edited hook \(updated.displayName) lines \(startLine)–\(endLine)",
                extraFields: ["line_count": lineCount(of: updatedCode)]
            )
        }
    }

    private static func tracerHookEditResult(
        engine: Engine,
        sessionID: UUID,
        hook: TracerConfig.Hook,
        summaryPrefix: String,
        extraFields: [String: Any] = [:]
    ) -> ActionResult {
        var payload = hookListEntry(hook)
        for (k, v) in extraFields { payload[k] = v }
        let apply = tracerHookApplyJSON(engine: engine, sessionID: sessionID, hookID: hook.id)
        payload["apply"] = apply
        return makeResult(jsonObject: payload, summary: summaryPrefix + applySummarySuffix(apply))
    }

    private static func hookListEntry(_ hook: TracerConfig.Hook) -> [String: Any] {
        var entry: [String: Any] = [
            "hook_id": hook.id.uuidString,
            "display_name": hook.displayName,
            "kind": hook.kind.rawValue,
            "state": hook.state.rawValue,
        ]
        if let arming = hook.itraceArming {
            entry["itrace_arming"] = [
                "max_invocations": arming.maxInvocations,
                "max_bytes_per_invocation": arming.maxBytesPerInvocation,
            ]
        }
        return entry
    }

    private static func tracerHookComponentStatus(engine: Engine, sessionID: UUID, hookID: UUID) -> [String: Any]? {
        guard let node = engine.node(forSessionID: sessionID),
            let ref = node.instruments.first(where: { $0.kind == .tracer }),
            let status = ref.componentStatuses[hookID]
        else { return nil }
        return status.toWireJSON()
    }

    private static func tracerHookApplyJSON(engine: Engine, sessionID: UUID, hookID: UUID) -> [String: Any] {
        guard let node = engine.node(forSessionID: sessionID),
            let ref = node.instruments.first(where: { $0.kind == .tracer }),
            ref.attachment == .attached
        else {
            return ["applied": false, "reason": "session not attached — edit persisted; will compile on next attach"]
        }
        if let status = ref.componentStatuses[hookID] {
            return ["applied": false, "compile_error": status.toWireJSON()]
        }
        if let status = ref.status {
            return ["applied": false, "instrument_error": status.toWireJSON()]
        }
        return ["applied": true]
    }

    private static func applySummarySuffix(_ apply: [String: Any]) -> String {
        if apply["applied"] as? Bool == true { return "" }
        if let err = apply["compile_error"] as? [String: Any], let msg = err["message"] as? String {
            return " — compile error: \(msg.prefix(80))"
        }
        if let err = apply["instrument_error"] as? [String: Any], let msg = err["message"] as? String {
            return " — instrument error: \(msg.prefix(80))"
        }
        if let reason = apply["reason"] as? String {
            return " — \(reason)"
        }
        return ""
    }

    private static func registerRemoveTracerHook(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "remove_tracer_hook",
            description: "Remove a tracer hook from the session.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"hook_id":{"type":"string"}},"required":["session_id","hook_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let hookID = (invocation.args["hook_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid hook_id", code: .invalidInput)
            }
            let removed = await engine.removeTracerHook(sessionID: sessionID, hookID: hookID)
            guard removed else {
                return errorResult("no tracer hook with id \(hookID)", code: .notFound)
            }
            let payload: [String: Any] = ["hook_id": hookID.uuidString, "removed": true]
            return makeResult(jsonObject: payload, summary: "Removed hook \(hookID)")
        }
    }

    // MARK: - custom instruments

    private static func registerListInstruments(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_instruments",
            description: "List instrument definitions known to this project — both editable custom instruments and shipped hookpacks. Each entry has `id` (opaque descriptor id; pass to attach_instrument), `kind` (custom | hookpack), `name`, `icon`. Custom instruments also report `def_id` (UUID for the custom_instrument_file/def tools) and source counts.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let array: [[String: Any]] = engine.descriptors.compactMap { instrumentDescriptorListEntry($0, engine: engine) }
            return makeResult(jsonObject: array, summary: "\(array.count) instrument\(array.count == 1 ? "" : "s")")
        }
    }

    private static func instrumentDescriptorListEntry(_ descriptor: InstrumentDescriptor, engine: Engine) -> [String: Any]? {
        var entry: [String: Any] = [
            "id": descriptor.id,
            "name": descriptor.displayName,
            "icon": describeIcon(descriptor.icon),
        ]
        switch descriptor.kind {
        case .tracer:
            entry["kind"] = "tracer"
        case .custom:
            guard let defID = UUID(uuidString: descriptor.sourceIdentifier),
                let def = engine.customInstruments.def(withId: defID)
            else { return nil }
            entry["kind"] = "custom"
            entry["def_id"] = defID.uuidString
            entry["feature_count"] = def.features.count
            entry["widget_count"] = def.widgets.count
        case .hookPack:
            entry["kind"] = "hookpack"
        case .codeShare:
            return nil
        }
        return entry
    }

    private static func registerReadCustomInstrument(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_custom_instrument",
            description: "Read a custom instrument's metadata: entrypoint, features, widgets, and the list of file paths. File contents are NOT included — call read_custom_instrument_file for each path you need.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"}},"required":["def_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentDef(invocation.args, engine: engine) { engine, defID, def in
                let files = engine.customInstruments.files(forDefID: defID)
                return makeResult(jsonObject: customInstrumentJSON(def: def, files: files), summary: "Custom instrument \(def.name)")
            }
        }
    }

    private static func registerCreateCustomInstrument(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "create_custom_instrument",
            description: "Create a custom instrument definition seeded with a `main.ts` file containing the canonical skeleton (the entrypoint). Use write_custom_instrument_file to replace its contents, and add helper files as needed. Optional 'icon' is a catalog id (e.g. wand-stars, bug, scope, network). Optional 'features' declares config toggles; 'widgets' declares live UI elements.",
            inputSchemaJSON: """
                {"type":"object","properties":{"name":{"type":"string"},"icon":{"type":"string","description":"Catalog id like wand-stars, bug, scope, network — see list_custom_instrument_icons"},"compatibility":\(compatibilitySchemaJSON),"features":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"enabled_by_default":{"type":"boolean","default":true}},"required":["id","name"],"additionalProperties":false}},"widgets":\(widgetsSchemaJSON)},"required":["name"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let name = invocation.args["name"] as? String, !name.isEmpty else {
                return errorResult("missing name", code: .invalidInput)
            }
            let icon = parseIconArg(invocation.args["icon"] as? String)
            let compatibility = parseCompatibilityArg(invocation.args["compatibility"])
            let features = parseFeaturesArg(invocation.args["features"])
            let widgets = parseWidgetsArg(invocation.args["widgets"])
            var def = engine.createCustomInstrument(name: name, icon: icon)
            if !compatibility.isUniversal || !features.isEmpty || !widgets.isEmpty {
                def.compatibility = compatibility
                def.features = features
                def.widgets = widgets
                engine.updateCustomInstrument(def)
            }
            return makeResult(
                jsonObject: ["def_id": def.id.uuidString, "name": def.name, "entrypoint": def.entrypoint],
                summary: "Created custom instrument \(def.name)"
            )
        }
    }

    private static func registerUpdateCustomInstrument(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "update_custom_instrument",
            description: "Update a custom instrument's metadata: name, icon, compatibility, features, or widgets. Only fields you pass change. Passing 'features' or 'widgets' replaces the entire list — pass an empty array to clear. File contents are managed via write_custom_instrument_file; the entrypoint via set_custom_instrument_entrypoint.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"},"name":{"type":"string"},"icon":{"type":"string"},"compatibility":\(compatibilitySchemaJSON),"features":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"enabled_by_default":{"type":"boolean","default":true}},"required":["id","name"],"additionalProperties":false}},"widgets":\(widgetsSchemaJSON)},"required":["def_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentDef(invocation.args, engine: engine) { engine, _, defConst in
                var def = defConst
                if let name = invocation.args["name"] as? String, !name.isEmpty {
                    def.name = name
                }
                if let iconID = invocation.args["icon"] as? String {
                    def.icon = parseIconArg(iconID)
                }
                if invocation.args["compatibility"] != nil {
                    def.compatibility = parseCompatibilityArg(invocation.args["compatibility"])
                }
                if invocation.args["features"] != nil {
                    def.features = parseFeaturesArg(invocation.args["features"])
                }
                if invocation.args["widgets"] != nil {
                    def.widgets = parseWidgetsArg(invocation.args["widgets"])
                }
                engine.updateCustomInstrument(def)
                await engine.awaitCustomInstrumentReload(defID: def.id)
                return customInstrumentEditResult(
                    engine: engine,
                    defID: def.id,
                    summaryPrefix: "Updated custom instrument \(def.name)",
                    extraFields: ["name": def.name]
                )
            }
        }
    }

    private static func registerListCustomInstrumentFiles(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_custom_instrument_files",
            description: "List the file paths inside a custom instrument's source tree. Contents are not included; call read_custom_instrument_file for each path you need.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"}},"required":["def_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentDef(invocation.args, engine: engine) { engine, defID, def in
                let paths = engine.customInstruments.files(forDefID: defID).map(\.path).sorted()
                return makeResult(
                    jsonObject: ["def_id": defID.uuidString, "entrypoint": def.entrypoint, "paths": paths],
                    summary: "\(paths.count) file\(paths.count == 1 ? "" : "s") in \(def.name)"
                )
            }
        }
    }

    private static func registerReadCustomInstrumentFile(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_custom_instrument_file",
            description: "Read one file's TypeScript source from a custom instrument. The `content` field is line-numbered (1-based, `<lineno>\\t<text>\\n`) so you can target edit_custom_instrument_file precisely; strip the prefix before reusing the text elsewhere. `line_count` is also returned.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"},"path":{"type":"string"}},"required":["def_id","path"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentFile(invocation.args, engine: engine) { _, defID, _, file in
                makeResult(
                    jsonObject: [
                        "def_id": defID.uuidString,
                        "path": file.path,
                        "content": numberedContent(file.content),
                        "line_count": lineCount(of: file.content),
                    ],
                    summary: "Read \(file.path)"
                )
            }
        }
    }

    private static func registerWriteCustomInstrumentFile(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "write_custom_instrument_file",
            description: "Create or replace the contents of one file in a custom instrument. Path is relative inside the instrument's source tree (subdirectories allowed). Use this to split an instrument across multiple files by concept (e.g. symbols.ts, decoder.ts); imports between them must use a `.js` extension even though the on-disk file is `.ts` (e.g. `import { resolveSymbol } from \"./symbols.js\"`) — standard NodeNext/ESM convention enforced by the bundler. Running instances are recompiled.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"},"path":{"type":"string"},"content":{"type":"string"}},"required":["def_id","path","content"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false,
            codePreview: CodePreviewArg(field: "content", language: .fridaTypeScript)
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentDef(invocation.args, engine: engine) { engine, defID, _ in
                guard let path = invocation.args["path"] as? String, !path.isEmpty else {
                    return errorResult("missing path", code: .invalidInput)
                }
                guard let content = invocation.args["content"] as? String else {
                    return errorResult("missing content", code: .invalidInput)
                }
                do {
                    let writtenPath = try engine.writeCustomInstrumentFile(defID: defID, path: path, content: content)
                    await engine.awaitCustomInstrumentReload(defID: defID)
                    return customInstrumentEditResult(
                        engine: engine,
                        defID: defID,
                        summaryPrefix: "Wrote \(writtenPath)",
                        extraFields: ["path": writtenPath]
                    )
                } catch {
                    return errorResult(error.localizedDescription, code: .invalidInput)
                }
            }
        }
    }

    private static func registerEditCustomInstrumentFile(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "edit_custom_instrument_file",
            description: """
                Replace a contiguous range of lines in one file of a custom instrument. Lines are 1-based and inclusive; \
                `start_line` is the first line replaced and `end_line` is the last. To insert without replacing, pass \
                `end_line = start_line - 1` (inserts before `start_line`); to append, use `start_line = line_count + 1, \
                end_line = line_count`. `new_content` may span multiple lines and does not need a trailing newline. Prefer \
                this over write_custom_instrument_file for targeted edits to large files. Running instances are recompiled.
                """,
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"},"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":0},"new_content":{"type":"string"}},"required":["def_id","path","start_line","end_line","new_content"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false,
            codePreview: CodePreviewArg(field: "new_content", language: .fridaTypeScript)
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentFile(invocation.args, engine: engine) { engine, defID, _, file in
                guard let startLine = invocation.args["start_line"] as? Int else {
                    return errorResult("missing or invalid start_line", code: .invalidInput)
                }
                guard let endLine = invocation.args["end_line"] as? Int else {
                    return errorResult("missing or invalid end_line", code: .invalidInput)
                }
                guard let newContent = invocation.args["new_content"] as? String else {
                    return errorResult("missing new_content", code: .invalidInput)
                }
                let updated: String
                switch spliceLines(in: file.content, startLine: startLine, endLine: endLine, replacement: newContent) {
                case .success(let result):
                    updated = result
                case .failure(let message):
                    return errorResult(message, code: .invalidInput)
                }
                do {
                    let writtenPath = try engine.writeCustomInstrumentFile(defID: defID, path: file.path, content: updated)
                    await engine.awaitCustomInstrumentReload(defID: defID)
                    return customInstrumentEditResult(
                        engine: engine,
                        defID: defID,
                        summaryPrefix: "Edited \(writtenPath) lines \(startLine)–\(endLine)",
                        extraFields: ["path": writtenPath, "line_count": lineCount(of: updated)]
                    )
                } catch {
                    return errorResult(error.localizedDescription, code: .invalidInput)
                }
            }
        }
    }

    private static func registerDeleteCustomInstrumentFile(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "delete_custom_instrument_file",
            description: "Delete one file from a custom instrument. Refuses to delete the entrypoint — call set_custom_instrument_entrypoint first to point at a different file.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"},"path":{"type":"string"}},"required":["def_id","path"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentFile(invocation.args, engine: engine) { engine, defID, def, file in
                if def.entrypoint == file.path {
                    return errorResult("cannot delete entrypoint '\(file.path)' — re-point with set_custom_instrument_entrypoint first", code: .invalidInput)
                }
                do {
                    try engine.deleteCustomInstrumentFile(defID: defID, path: file.path)
                    await engine.awaitCustomInstrumentReload(defID: defID)
                    return customInstrumentEditResult(
                        engine: engine,
                        defID: defID,
                        summaryPrefix: "Deleted \(file.path)",
                        extraFields: ["path": file.path]
                    )
                } catch {
                    return errorResult(error.localizedDescription, code: .invalidInput)
                }
            }
        }
    }

    private static func registerRenameCustomInstrumentFile(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "rename_custom_instrument_file",
            description: "Rename a file inside a custom instrument. If the renamed file was the entrypoint, the entrypoint is updated automatically.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"}},"required":["def_id","from","to"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentDef(invocation.args, engine: engine) { engine, defID, _ in
                guard let from = invocation.args["from"] as? String, !from.isEmpty,
                    let to = invocation.args["to"] as? String, !to.isEmpty
                else {
                    return errorResult("missing from/to", code: .invalidInput)
                }
                guard engine.customInstruments.file(defID: defID, path: from) != nil else {
                    return errorResult("no file '\(from)'", code: .notFound)
                }
                do {
                    let renamedPath = try engine.renameCustomInstrumentFile(defID: defID, from: from, to: to)
                    await engine.awaitCustomInstrumentReload(defID: defID)
                    return customInstrumentEditResult(
                        engine: engine,
                        defID: defID,
                        summaryPrefix: "Renamed \(from) → \(renamedPath)",
                        extraFields: ["from": from, "to": renamedPath]
                    )
                } catch {
                    return errorResult(error.localizedDescription, code: .invalidInput)
                }
            }
        }
    }

    private static func registerSetCustomInstrumentEntrypoint(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "set_custom_instrument_entrypoint",
            description: "Mark which file is the entrypoint the agent loads first. The path must exist among the instrument's files.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"},"path":{"type":"string"}},"required":["def_id","path"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            await withResolvedCustomInstrumentFile(invocation.args, engine: engine) { engine, defID, _, file in
                do {
                    let entrypoint = try engine.setCustomInstrumentEntrypoint(defID: defID, path: file.path)
                    await engine.awaitCustomInstrumentReload(defID: defID)
                    return customInstrumentEditResult(
                        engine: engine,
                        defID: defID,
                        summaryPrefix: "Entrypoint set to \(entrypoint)",
                        extraFields: ["entrypoint": entrypoint]
                    )
                } catch {
                    return errorResult(error.localizedDescription, code: .invalidInput)
                }
            }
        }
    }

    private static func customInstrumentEditResult(
        engine: Engine,
        defID: UUID,
        summaryPrefix: String,
        extraFields: [String: Any] = [:]
    ) -> ActionResult {
        var payload: [String: Any] = ["def_id": defID.uuidString]
        for (k, v) in extraFields { payload[k] = v }
        let apply = customInstrumentApplyJSON(engine: engine, defID: defID)
        payload["apply"] = apply
        return makeResult(jsonObject: payload, summary: summaryPrefix + customInstrumentSummarySuffix(apply))
    }

    private static func customInstrumentApplyJSON(engine: Engine, defID: UUID) -> [String: Any] {
        let key = defID.uuidString
        var appliedSessions: [[String: Any]] = []
        var errors: [[String: Any]] = []
        var detachedSessions: [String] = []
        for (sessionID, instances) in engine.instrumentsBySession {
            for inst in instances where inst.kind == .custom && inst.sourceIdentifier == key {
                guard let node = engine.node(forSessionID: sessionID),
                    let ref = node.instruments.first(where: { $0.id == inst.id })
                else {
                    detachedSessions.append(sessionID.uuidString)
                    continue
                }
                if let status = ref.status {
                    errors.append([
                        "session_id": sessionID.uuidString,
                        "instance_id": inst.id.uuidString,
                        "error": status.toWireJSON(),
                    ])
                } else if ref.attachment == .attached {
                    appliedSessions.append([
                        "session_id": sessionID.uuidString,
                        "instance_id": inst.id.uuidString,
                    ])
                } else {
                    detachedSessions.append(sessionID.uuidString)
                }
            }
        }
        var out: [String: Any] = ["applied_sessions": appliedSessions]
        if !errors.isEmpty { out["errors"] = errors }
        if !detachedSessions.isEmpty { out["detached_sessions"] = detachedSessions }
        return out
    }

    private static func customInstrumentSummarySuffix(_ apply: [String: Any]) -> String {
        if let errors = apply["errors"] as? [[String: Any]], let first = errors.first,
            let status = first["error"] as? [String: Any], let msg = status["message"] as? String
        {
            let n = errors.count
            return " — error on \(n) session\(n == 1 ? "" : "s"): \(msg.prefix(80))"
        }
        let appliedCount = (apply["applied_sessions"] as? [[String: Any]])?.count ?? 0
        if appliedCount > 0 {
            return " — applied on \(appliedCount) session\(appliedCount == 1 ? "" : "s")"
        }
        return ""
    }

    private static func registerDeleteCustomInstrument(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "delete_custom_instrument",
            description: "Delete a custom instrument definition. Any sessions where it's currently attached have the instance removed automatically.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"}},"required":["def_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let defID = (invocation.args["def_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid def_id", code: .invalidInput)
            }
            guard engine.customInstruments.def(withId: defID) != nil else {
                return errorResult("no custom instrument with id \(defID)", code: .notFound)
            }
            await engine.deleteCustomInstrument(defID)
            return makeResult(jsonObject: ["def_id": defID.uuidString, "removed": true], summary: "Deleted custom instrument \(defID)")
        }
    }

    private static func registerAttachInstrument(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "attach_instrument",
            description: "Attach an instrument (tracer, custom instrument, or hookpack) to a session. Pass the `id` returned by list_instruments. An instrument can only be attached once per session; calling again returns the existing instance with `already_attached: true`.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"id":{"type":"string","description":"Descriptor id from list_instruments"}},"required":["session_id","id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let descriptorID = invocation.args["id"] as? String, !descriptorID.isEmpty else {
                return errorResult("missing id", code: .invalidInput)
            }
            guard let descriptor = engine.descriptor(withID: descriptorID) else {
                return errorResult("no instrument with id '\(descriptorID)'", code: .notFound)
            }
            guard descriptor.kind != .codeShare else {
                return errorResult("codeshare snippets are attached via their own flow, not via this tool", code: .invalidInput)
            }
            if let existing = engine.instrumentsBySession[sessionID]?.first(where: {
                $0.kind == descriptor.kind && $0.sourceIdentifier == descriptor.sourceIdentifier
            }) {
                let payload: [String: Any] = [
                    "instrument_id": existing.id.uuidString,
                    "id": descriptor.id,
                    "kind": descriptor.kind.rawValue,
                    "session_id": sessionID.uuidString,
                    "already_attached": true,
                ]
                return makeResult(jsonObject: payload, summary: "\(descriptor.displayName) already attached to session")
            }
            guard let instance = await engine.addInstrument(
                kind: descriptor.kind,
                sourceIdentifier: descriptor.sourceIdentifier,
                configJSON: descriptor.makeInitialConfigJSON(),
                sessionID: sessionID
            ) else {
                return errorResult("could not attach \(descriptor.displayName) to session", code: .unavailable)
            }
            let payload: [String: Any] = [
                "instrument_id": instance.id.uuidString,
                "id": descriptor.id,
                "kind": descriptor.kind.rawValue,
                "session_id": sessionID.uuidString,
            ]
            return makeResult(jsonObject: payload, summary: "Attached \(descriptor.displayName) to session")
        }
    }

    private static func registerReadTracerHandlerTemplate(in catalog: ToolCatalog) {
        let spec = ActionSpec(
            name: "read_tracer_handler_template",
            description: "Return the canonical defineHandler() skeleton for a tracer hook. 'kind' is one of: instruction, native, objc, swift, java. Use this when authoring code for install_tracer_hook or update_tracer_hook.",
            inputSchemaJSON: """
                {"type":"object","properties":{"kind":{"type":"string","enum":["instruction","native","objc","swift","java"]}},"required":["kind"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { invocation in
            guard let kind = invocation.args["kind"] as? String else {
                return errorResult("missing kind", code: .invalidInput)
            }
            guard let template = tracerHandlerTemplate(kind: kind) else {
                return errorResult("unknown kind '\(kind)'", code: .invalidInput)
            }
            return makeResult(jsonObject: ["kind": kind, "template": template], summary: "\(kind) tracer handler template")
        }
    }

    private static func registerReadCustomInstrumentTemplate(in catalog: ToolCatalog) {
        let spec = ActionSpec(
            name: "read_custom_instrument_template",
            description: "Return the canonical TypeScript skeleton for a custom instrument: how create(ctx, config) is called, how to emit events via ctx.emit, how features are typed, and how dispose() should undo every side effect.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { _ in
            return makeResult(
                jsonObject: ["template": CustomInstrumentDef.defaultEntrypointSource],
                summary: "Custom instrument source template"
            )
        }
    }

    private static func registerReadCustomInstrumentTypings(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_custom_instrument_typings",
            description: "Return the TypeScript ambient declarations the editor injects when authoring this custom instrument's source: the shared CustomInstrument* surface plus the def-scoped CustomInstrumentFeatureMap and CustomInstrumentWidgetMap that narrow `config.features.<id>`, `ctx.widget(<id>)`, and the `onAction` parameter to the exact ids/series/actions you declared. Use this to write source that compiles against the same types Monaco enforces.",
            inputSchemaJSON: """
                {"type":"object","properties":{"def_id":{"type":"string"}},"required":["def_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let defID = (invocation.args["def_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid def_id", code: .invalidInput)
            }
            guard let def = engine.customInstruments.def(withId: defID) else {
                return errorResult("no custom instrument with id \(defID)", code: .notFound)
            }
            let scoped = CustomInstrumentTypings.defScopedDeclarations(for: def)
            let payload: [String: Any] = [
                "ambient": CustomInstrumentTypings.ambientDeclarations,
                "scoped": scoped,
            ]
            return makeResult(jsonObject: payload, summary: "Typings for \(def.name)")
        }
    }

    private static func registerLookupFridaAPI(in catalog: ToolCatalog) {
        let spec = ActionSpec(
            name: "lookup_frida_api",
            description: "Search Frida's GumJS TypeScript declarations. Returns matching declarations with their doc comments. Use this when the LLM training data may be stale (Frida 17 reorganised the Module API; symbols like findGlobalExportByName replaced the older findExportByName). Pass a function or class name as 'query' (case-insensitive substring match).",
            inputSchemaJSON: """
                {"type":"object","properties":{"query":{"type":"string"},"max_matches":{"type":"integer","minimum":1,"maximum":40,"default":12}},"required":["query"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { invocation in
            guard let query = (invocation.args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
                return errorResult("missing query", code: .invalidInput)
            }
            let fridaGumSource = TypeScriptTypings.fridaGum.map(\.content).joined(separator: "\n")
            let cap = (invocation.args["max_matches"] as? Int) ?? 12
            let matches = searchFridaDeclarations(in: fridaGumSource, query: query, limit: cap)
            let payload: [String: Any] = [
                "query": query,
                "match_count": matches.count,
                "matches": matches,
            ]
            return makeResult(
                jsonObject: payload,
                summary: matches.isEmpty ? "No declarations matched '\(query)'" : "\(matches.count) declaration\(matches.count == 1 ? "" : "s") matched '\(query)'"
            )
        }
    }

    private static func tracerHandlerTemplate(kind: String) -> String? {
        switch kind {
        case "instruction":
            return defaultTracerCode(kind: .instruction, anchor: .absolute(0), displayName: "myTarget")
        case "native":
            return defaultTracerCode(kind: .function, anchor: .absolute(0), displayName: "myTarget")
        case "objc":
            return defaultTracerCode(kind: .function, anchor: .objcMethod(selector: "-[MyClass doThing:]"), displayName: "-[MyClass doThing:]")
        case "swift":
            return defaultTracerCode(kind: .function, anchor: .swiftFunc(module: "MyModule", function: "MyType.doThing()"), displayName: "MyModule.MyType.doThing()")
        case "java":
            return defaultTracerCode(kind: .function, anchor: .javaMethod(className: "com.example.MyClass", methodName: "doThing"), displayName: "com.example.MyClass.doThing")
        default:
            return nil
        }
    }

    private static func searchFridaDeclarations(in source: String, query: String, limit: Int) -> [[String: String]] {
        let blocks = fridaDeclarationBlocks(from: source)
        let needle = query.lowercased()
        var matches: [[String: String]] = []
        for block in blocks {
            if block.declaration.lowercased().contains(needle) {
                matches.append([
                    "declaration": block.declaration,
                    "doc": block.doc,
                ])
                if matches.count >= limit { break }
            }
        }
        return matches
    }

    private struct FridaBlock {
        var doc: String
        var declaration: String
    }

    private static func fridaDeclarationBlocks(from source: String) -> [FridaBlock] {
        var blocks: [FridaBlock] = []
        var docLines: [String] = []
        var inDoc = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inDoc {
                docLines.append(line)
                if trimmed.hasSuffix("*/") { inDoc = false }
                continue
            }
            if trimmed.hasPrefix("/**") {
                docLines = [line]
                if trimmed.hasSuffix("*/") {
                    inDoc = false
                } else {
                    inDoc = true
                }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                docLines = []
                continue
            }
            blocks.append(FridaBlock(doc: docLines.joined(separator: "\n"), declaration: line))
            docLines = []
        }
        return blocks
    }

    private static func registerListPackages(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_packages",
            description: "List npm packages installed in the project's compiler workspace. These are available to all sessions, custom instruments, and tracer hooks. Common ones: frida-java-bridge (Android Java tracing), frida-objc-bridge.",
            inputSchemaJSON: """
                {"type":"object","properties":{},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] _ in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let array: [[String: Any]] = engine.installedPackages.map { pkg in
                var entry: [String: Any] = [
                    "name": pkg.name,
                    "version": pkg.version,
                ]
                if let alias = pkg.globalAlias, !alias.isEmpty {
                    entry["global_alias"] = alias
                }
                return entry
            }
            return makeResult(jsonObject: array, summary: "\(array.count) installed package\(array.count == 1 ? "" : "s")")
        }
    }

    private static func registerInstallPackage(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "install_package",
            description: "Install an npm package into the project's compiler workspace. Use this to enable runtime bridges (e.g. frida-java-bridge for Java tracing). Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"name":{"type":"string"},"version":{"type":"string","description":"npm semver range (e.g. ^7.0.0). Omit for latest."},"global_alias":{"type":"string","description":"Optional global identifier the package should expose at runtime (e.g. 'Java' for frida-java-bridge)."}},"required":["name"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let name = invocation.args["name"] as? String, !name.isEmpty else {
                return errorResult("missing name", code: .invalidInput)
            }
            let version = invocation.args["version"] as? String
            let globalAlias = invocation.args["global_alias"] as? String
            do {
                let pkg = try await engine.installPackage(name: name, versionSpec: version, globalAlias: globalAlias)
                let payload: [String: Any] = [
                    "name": pkg.name,
                    "version": pkg.version,
                ]
                return makeResult(jsonObject: payload, summary: "Installed \(pkg.name)@\(pkg.version)")
            } catch {
                return errorResult("install failed: \(error.localizedDescription)")
            }
        }
    }

    private static func registerRemovePackage(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "remove_package",
            description: "Remove a previously installed npm package from the project's compiler workspace. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let name = invocation.args["name"] as? String, !name.isEmpty else {
                return errorResult("missing name", code: .invalidInput)
            }
            guard let pkg = engine.installedPackages.first(where: { $0.name == name }) else {
                return errorResult("no installed package named '\(name)'", code: .notFound)
            }
            do {
                try await engine.removePackage(pkg)
                return makeResult(jsonObject: ["name": name, "removed": true], summary: "Removed \(name)")
            } catch {
                return errorResult("remove failed: \(error.localizedDescription)")
            }
        }
    }

    private static func registerStartThreadTrace(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "start_thread_trace",
            description: "Start an instruction trace for a specific thread. Returns trace_id; pair with stop_trace once you've triggered the behavior you want to observe. Trace data is bounded by the agent's ring buffer, but the longer it runs the more is captured — keep it short.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"thread_id":{"type":"integer","minimum":0},"thread_name":{"type":"string"}},"required":["session_id","thread_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let threadIDRaw = invocation.args["thread_id"] as? Int, threadIDRaw >= 0 else {
                return errorResult("missing or invalid thread_id", code: .invalidInput)
            }
            let threadName = invocation.args["thread_name"] as? String
            guard let trace = await engine.startThreadTrace(sessionID: sessionID, threadID: UInt(threadIDRaw), threadName: threadName) else {
                return errorResult("failed to start thread trace")
            }
            return makeResult(jsonObject: traceListEntry(trace), summary: "Started \(trace.displayName)")
        }
    }

    private static func registerStopTrace(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "stop_trace",
            description: "Stop a running instruction trace. After this returns, summarize_trace and the read_* tools have a stable picture.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"trace_id":{"type":"string"}},"required":["session_id","trace_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let traceID = (invocation.args["trace_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid trace_id", code: .invalidInput)
            }
            await engine.stopThreadTrace(traceID: traceID, sessionID: sessionID)
            return makeResult(jsonObject: ["trace_id": traceID.uuidString, "stopped": true], summary: "Stopped trace \(traceID)")
        }
    }

    private static func registerListTraces(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_traces",
            description: "List instruction traces saved on this session — id, origin (functionCall hookID/callIndex or thread tid), display name, status, byte size. Use summarize_trace before reading raw entries.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            let traces = engine.tracesBySession[sessionID] ?? []
            let array = traces.map(traceListEntry)
            return makeResult(jsonObject: array, summary: "\(traces.count) trace\(traces.count == 1 ? "" : "s")")
        }
    }

    private static func registerSummarizeTrace(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "summarize_trace",
            description: "Summarize a trace: total entries, function-call count, top-N functions by entry count. Cheap; doesn't return raw entries.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"trace_id":{"type":"string"},"top_n":{"type":"integer","minimum":1,"maximum":50,"default":10}},"required":["session_id","trace_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let traceID = (invocation.args["trace_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid trace_id", code: .invalidInput)
            }
            guard let decoded = await engine.decodeTrace(traceID: traceID, sessionID: sessionID) else {
                return errorResult("could not decode trace \(traceID)")
            }
            let topN = (invocation.args["top_n"] as? Int) ?? 10
            let topCalls = decoded.functionCalls
                .sorted { $0.entryCount > $1.entryCount }
                .prefix(topN)
                .map { call -> [String: Any] in
                    [
                        "function_name": call.functionName,
                        "entry_count": call.entryCount,
                        "start_index": call.startIndex,
                        "end_index": call.endIndex,
                    ]
                }
            let firstAddr = decoded.entries.first.map { String(format: "0x%llx", $0.blockAddress) }
            let lastAddr = decoded.entries.last.map { String(format: "0x%llx", $0.blockAddress) }
            var payload: [String: Any] = [
                "trace_id": traceID.uuidString,
                "entry_count": decoded.entries.count,
                "function_call_count": decoded.functionCalls.count,
                "register_count": decoded.registerNames.count,
                "top_function_calls": topCalls,
            ]
            if let firstAddr { payload["first_block_address"] = firstAddr }
            if let lastAddr { payload["last_block_address"] = lastAddr }
            return makeResult(jsonObject: payload, summary: "\(decoded.entries.count) entries, \(decoded.functionCalls.count) function calls")
        }
    }

    private static func registerListTraceFunctionCalls(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_trace_function_calls",
            description: "Paginate through function calls observed in a trace. Returns name, entry range, and entry count — no addresses or register state.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"trace_id":{"type":"string"},"offset":{"type":"integer","minimum":0,"default":0},"limit":{"type":"integer","minimum":1,"maximum":200,"default":50}},"required":["session_id","trace_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let traceID = (invocation.args["trace_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid trace_id", code: .invalidInput)
            }
            guard let decoded = await engine.decodeTrace(traceID: traceID, sessionID: sessionID) else {
                return errorResult("could not decode trace \(traceID)")
            }
            let offset = (invocation.args["offset"] as? Int) ?? 0
            let limit = (invocation.args["limit"] as? Int) ?? 50
            let calls = decoded.functionCalls
            let slice = calls.dropFirst(offset).prefix(limit)
            let array = slice.enumerated().map { idx, call -> [String: Any] in
                [
                    "index": offset + idx,
                    "function_name": call.functionName,
                    "start_index": call.startIndex,
                    "end_index": call.endIndex,
                    "entry_count": call.entryCount,
                ]
            }
            let payload: [String: Any] = [
                "trace_id": traceID.uuidString,
                "total": calls.count,
                "offset": offset,
                "function_calls": array,
            ]
            return makeResult(jsonObject: payload, summary: "\(slice.count) of \(calls.count) function calls")
        }
    }

    private static func registerReadTraceFunctionCall(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_trace_function_call",
            description: "Read the basic blocks executed within one function call (resolved by index from list_trace_function_calls). Returns each block's address and size, capped to max_blocks. Pair with the disassemble tool for instruction text.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"trace_id":{"type":"string"},"call_index":{"type":"integer","minimum":0},"max_blocks":{"type":"integer","minimum":1,"maximum":1000,"default":200}},"required":["session_id","trace_id","call_index"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let traceID = (invocation.args["trace_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid trace_id", code: .invalidInput)
            }
            guard let callIndex = invocation.args["call_index"] as? Int, callIndex >= 0 else {
                return errorResult("missing or invalid call_index", code: .invalidInput)
            }
            guard let decoded = await engine.decodeTrace(traceID: traceID, sessionID: sessionID) else {
                return errorResult("could not decode trace \(traceID)")
            }
            guard callIndex < decoded.functionCalls.count else {
                return errorResult("call_index \(callIndex) out of range (\(decoded.functionCalls.count) calls)", code: .invalidInput)
            }
            let call = decoded.functionCalls[callIndex]
            let maxBlocks = (invocation.args["max_blocks"] as? Int) ?? 200
            let cappedEnd = min(call.endIndex, call.startIndex + maxBlocks)
            let blocks = decoded.entries[call.startIndex..<cappedEnd].enumerated().map { offset, entry -> [String: Any] in
                [
                    "entry_index": call.startIndex + offset,
                    "address": String(format: "0x%llx", entry.blockAddress),
                    "size": entry.blockSize,
                    "name": entry.blockName,
                ]
            }
            let payload: [String: Any] = [
                "trace_id": traceID.uuidString,
                "call_index": callIndex,
                "function_name": call.functionName,
                "start_index": call.startIndex,
                "end_index": call.endIndex,
                "returned": blocks.count,
                "truncated": blocks.count < call.entryCount,
                "blocks": blocks,
            ]
            return makeResult(jsonObject: payload, summary: "\(blocks.count) of \(call.entryCount) blocks for \(call.shortName)")
        }
    }

    private static func registerReadTraceRegisterState(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_trace_register_state",
            description: "Return the register state at a specific entry in a trace. Useful for spotting argument or return values around a particular block. Pass the entry_index you got from read_trace_function_call.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"trace_id":{"type":"string"},"entry_index":{"type":"integer","minimum":0}},"required":["session_id","trace_id","entry_index"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let traceID = (invocation.args["trace_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return errorResult("missing or invalid trace_id", code: .invalidInput)
            }
            guard let entryIndex = invocation.args["entry_index"] as? Int, entryIndex >= 0 else {
                return errorResult("missing or invalid entry_index", code: .invalidInput)
            }
            guard let decoded = await engine.decodeTrace(traceID: traceID, sessionID: sessionID) else {
                return errorResult("could not decode trace \(traceID)")
            }
            guard entryIndex < decoded.registerStates.count else {
                return errorResult("entry_index \(entryIndex) out of range (\(decoded.registerStates.count) entries)", code: .invalidInput)
            }
            let state = decoded.registerStates[entryIndex]
            var values: [String: String] = [:]
            for (idx, value) in state.values {
                guard idx < decoded.registerNames.count else { continue }
                values[decoded.registerNames[idx]] = String(format: "0x%llx", value)
            }
            let changed = state.changed.compactMap { idx -> String? in
                guard idx < decoded.registerNames.count else { return nil }
                return decoded.registerNames[idx]
            }
            let payload: [String: Any] = [
                "trace_id": traceID.uuidString,
                "entry_index": entryIndex,
                "registers": values,
                "changed": changed,
            ]
            return makeResult(jsonObject: payload, summary: "Register state at entry \(entryIndex)")
        }
    }

    private static func traceListEntry(_ trace: ITrace) -> [String: Any] {
        var entry: [String: Any] = [
            "trace_id": trace.id.uuidString,
            "display_name": trace.displayName,
            "status": trace.isRunning ? "running" : "stopped",
            "data_size": trace.dataSize,
            "started_at": ISO8601DateFormatter().string(from: trace.startedAt),
        ]
        if let stoppedAt = trace.stoppedAt {
            entry["stopped_at"] = ISO8601DateFormatter().string(from: stoppedAt)
        }
        switch trace.origin {
        case .functionCall(let hookID, let callIndex):
            entry["origin"] = [
                "kind": "function_call",
                "hook_id": hookID.uuidString,
                "call_index": callIndex,
            ]
        case .thread(let tid, let name):
            var origin: [String: Any] = [
                "kind": "thread",
                "thread_id": tid,
            ]
            if let name { origin["thread_name"] = name }
            entry["origin"] = origin
        }
        return entry
    }

    private static func describeIcon(_ icon: InstrumentIcon) -> String {
        switch icon {
        case .symbolic(let id): return id
        case .pixels: return "pixels"
        }
    }

    private static func parseIconArg(_ raw: String?) -> InstrumentIcon {
        guard let raw, !raw.isEmpty else {
            return .symbolic(InstrumentIconCatalog.default.id)
        }
        return .symbolic(InstrumentIconCatalog.concept(forID: raw).id)
    }

    private static let compatibilitySchemaJSON: String = """
        {"type":"object","description":"Optional platform/OS/arch gate. Omit a field to leave that axis unconstrained; pass an empty object to clear all constraints.","properties":{"platforms":{"type":"array","items":{"type":"string","enum":["windows","darwin","linux","freebsd","qnx","barebone"]}},"osIDs":{"type":"array","items":{"type":"string","enum":["windows","macos","linux","ios","watchos","tvos","visionos","android","freebsd","qnx"]}},"archs":{"type":"array","items":{"type":"string","enum":["ia32","x64","arm","arm64","mips"]}}},"additionalProperties":false}
        """

    private static func parseCompatibilityArg(_ raw: Any?) -> InstrumentCompatibility {
        guard let obj = raw as? [String: Any] else { return .universal }
        let platforms = (obj["platforms"] as? [String]).map(Set.init)
        let osIDs = (obj["osIDs"] as? [String]).map(Set.init)
        let archs = (obj["archs"] as? [String]).map(Set.init)
        return InstrumentCompatibility(platforms: platforms, osIDs: osIDs, archs: archs)
    }

    private static func parseFeaturesArg(_ raw: Any?) -> [CustomInstrumentDef.Feature] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let id = obj["id"] as? String, let name = obj["name"] as? String else { return nil }
            let enabled = (obj["enabled_by_default"] as? Bool) ?? true
            return CustomInstrumentDef.Feature(id: id, name: name, schema: .boolean(default: enabled), optional: false, enabledByDefault: enabled)
        }
    }

    private static let widgetsSchemaJSON: String = """
        {"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string","enum":["counter","histogram","graph","list","table","hex","console"]},"persistence":{"type":"string","enum":["none","session"],"default":"none","description":"'none' = data lives in memory, lost on detach. 'session' = data survives reattach and app restart, replayed to create() via the `restored` argument."},"max_points":{"type":"integer","minimum":1,"default":5000,"description":"For kind=graph: rolling cap per series. Oldest points drop when exceeded."},"max_items":{"type":"integer","minimum":1,"default":1000,"description":"For kind=list: rolling cap. Oldest items drop when exceeded."},"max_rows":{"type":"integer","minimum":1,"default":1000,"description":"For kind=table: rolling cap on rows."},"max_buckets":{"type":"integer","minimum":1,"default":100,"description":"For kind=histogram: rolling cap on bucket count."},"max_bytes":{"type":"integer","minimum":1,"default":16384,"description":"For kind=hex: trailing-window cap on bytes shown."},"max_entries":{"type":"integer","minimum":1,"default":1000,"description":"For kind=console: rolling cap on entries shown. Oldest entries drop when exceeded."},"unit":{"type":"string","description":"For kind=counter: optional default unit label rendered next to the value."},"prompt":{"type":"string","description":"For kind=console: optional prompt glyph rendered before each entry and on the input row (default '›')."},"placeholder":{"type":"string","description":"For kind=console: optional placeholder text shown in the input field."},"run_button_label":{"type":"string","description":"For kind=console: optional label for the submit button (default 'Run')."},"series":{"type":"array","description":"For kind=graph: line series the agent will push points to.","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"required":["id","name"],"additionalProperties":false}},"columns":{"type":"array","description":"For kind=table: ordered columns; each row's cells map column id to string.","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"alignment":{"type":"string","enum":["leading","trailing"],"default":"leading"}},"required":["id","name"],"additionalProperties":false}},"actions":{"type":"array","description":"For kind=list/table: per-item action buttons; clicks invoke onAction with {widget,action,item}.","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"}},"required":["id","name"],"additionalProperties":false}}},"required":["id","name","kind"],"additionalProperties":false}}
        """

    private static func parseWidgetsArg(_ raw: Any?) -> [InstrumentWidget] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let id = obj["id"] as? String,
                let name = obj["name"] as? String,
                let kindStr = obj["kind"] as? String
            else { return nil }
            let persistence = (obj["persistence"] as? String).flatMap(InstrumentWidget.Persistence.init(rawValue:)) ?? .none
            switch kindStr {
            case "counter":
                let cfg = InstrumentWidget.CounterConfig(unit: obj["unit"] as? String)
                return InstrumentWidget(id: id, name: name, kind: .counter(cfg), persistence: persistence)
            case "histogram":
                let maxBuckets = (obj["max_buckets"] as? Int) ?? InstrumentWidget.HistogramConfig.defaultMaxBuckets
                return InstrumentWidget(id: id, name: name, kind: .histogram(InstrumentWidget.HistogramConfig(maxBuckets: max(1, maxBuckets))), persistence: persistence)
            case "graph":
                let cfg = parseGraphConfigArg(seriesRaw: obj["series"], maxPointsRaw: obj["max_points"])
                return InstrumentWidget(id: id, name: name, kind: .graph(cfg), persistence: persistence)
            case "list":
                let cfg = parseListConfigArg(actionsRaw: obj["actions"], maxItemsRaw: obj["max_items"])
                return InstrumentWidget(id: id, name: name, kind: .list(cfg), persistence: persistence)
            case "table":
                let cfg = parseTableConfigArg(columnsRaw: obj["columns"], actionsRaw: obj["actions"], maxRowsRaw: obj["max_rows"])
                return InstrumentWidget(id: id, name: name, kind: .table(cfg), persistence: persistence)
            case "hex":
                let maxBytes = (obj["max_bytes"] as? Int) ?? InstrumentWidget.HexConfig.defaultMaxBytes
                return InstrumentWidget(id: id, name: name, kind: .hex(InstrumentWidget.HexConfig(maxBytes: max(1, maxBytes))), persistence: persistence)
            case "console":
                let cfg = parseConsoleConfigArg(
                    promptRaw: obj["prompt"],
                    placeholderRaw: obj["placeholder"],
                    runLabelRaw: obj["run_button_label"],
                    maxEntriesRaw: obj["max_entries"]
                )
                return InstrumentWidget(id: id, name: name, kind: .console(cfg), persistence: persistence)
            default:
                return nil
            }
        }
    }

    private static func parseGraphConfigArg(seriesRaw: Any?, maxPointsRaw: Any?) -> InstrumentWidget.GraphConfig {
        let entries = (seriesRaw as? [[String: Any]]) ?? []
        let series = entries.compactMap { obj -> InstrumentWidget.Series? in
            guard let sid = obj["id"] as? String, let sname = obj["name"] as? String else { return nil }
            return InstrumentWidget.Series(id: sid, name: sname)
        }
        let maxPoints = (maxPointsRaw as? Int) ?? InstrumentWidget.GraphConfig.defaultMaxPoints
        return InstrumentWidget.GraphConfig(series: series, maxPoints: max(1, maxPoints))
    }

    private static func parseListConfigArg(actionsRaw: Any?, maxItemsRaw: Any?) -> InstrumentWidget.ListConfig {
        let entries = (actionsRaw as? [[String: Any]]) ?? []
        let actions = entries.compactMap { obj -> InstrumentWidget.Action? in
            guard let aid = obj["id"] as? String, let aname = obj["name"] as? String else { return nil }
            return InstrumentWidget.Action(id: aid, name: aname)
        }
        let maxItems = (maxItemsRaw as? Int) ?? InstrumentWidget.ListConfig.defaultMaxItems
        return InstrumentWidget.ListConfig(actions: actions, maxItems: max(1, maxItems))
    }

    private static func parseTableConfigArg(columnsRaw: Any?, actionsRaw: Any?, maxRowsRaw: Any?) -> InstrumentWidget.TableConfig {
        let columnEntries = (columnsRaw as? [[String: Any]]) ?? []
        let columns = columnEntries.compactMap { obj -> InstrumentWidget.Column? in
            guard let cid = obj["id"] as? String, let cname = obj["name"] as? String else { return nil }
            let alignment = (obj["alignment"] as? String).flatMap(InstrumentWidget.Column.Alignment.init(rawValue:)) ?? .leading
            return InstrumentWidget.Column(id: cid, name: cname, alignment: alignment)
        }
        let actionEntries = (actionsRaw as? [[String: Any]]) ?? []
        let actions = actionEntries.compactMap { obj -> InstrumentWidget.Action? in
            guard let aid = obj["id"] as? String, let aname = obj["name"] as? String else { return nil }
            return InstrumentWidget.Action(id: aid, name: aname)
        }
        let maxRows = (maxRowsRaw as? Int) ?? InstrumentWidget.TableConfig.defaultMaxRows
        return InstrumentWidget.TableConfig(columns: columns, actions: actions, maxRows: max(1, maxRows))
    }

    private static func parseConsoleConfigArg(
        promptRaw: Any?,
        placeholderRaw: Any?,
        runLabelRaw: Any?,
        maxEntriesRaw: Any?
    ) -> InstrumentWidget.ConsoleConfig {
        let maxEntries = (maxEntriesRaw as? Int) ?? InstrumentWidget.ConsoleConfig.defaultMaxEntries
        return InstrumentWidget.ConsoleConfig(
            prompt: optionalString(promptRaw),
            placeholder: optionalString(placeholderRaw),
            runButtonLabel: optionalString(runLabelRaw),
            maxEntries: max(1, maxEntries)
        )
    }

    private static func optionalString(_ raw: Any?) -> String? {
        guard let str = raw as? String, !str.isEmpty else { return nil }
        return str
    }

    private static func customInstrumentJSON(def: CustomInstrumentDef, files: [CustomInstrumentFile]) -> [String: Any] {
        let features: [[String: Any]] = def.features.map { feature in
            [
                "id": feature.id,
                "name": feature.name,
                "enabled_by_default": feature.enabledByDefault,
            ]
        }
        let widgets: [[String: Any]] = def.widgets.map(customInstrumentWidgetJSON)
        return [
            "id": def.id.uuidString,
            "name": def.name,
            "icon": describeIcon(def.icon),
            "entrypoint": def.entrypoint,
            "paths": files.map(\.path).sorted(),
            "features": features,
            "widgets": widgets,
        ]
    }

    private static func withResolvedCustomInstrumentDef(
        _ args: [String: Any],
        engine engineMaybe: Engine?,
        body: @MainActor (Engine, UUID, CustomInstrumentDef) async -> ActionResult
    ) async -> ActionResult {
        guard let engine = engineMaybe else { return errorResult("engine unavailable", code: .unavailable) }
        guard let defID = (args["def_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            return errorResult("missing or invalid def_id", code: .invalidInput)
        }
        guard let def = engine.customInstruments.def(withId: defID) else {
            return errorResult("no custom instrument with id \(defID)", code: .notFound)
        }
        return await body(engine, defID, def)
    }

    private static func withResolvedCustomInstrumentFile(
        _ args: [String: Any],
        engine engineMaybe: Engine?,
        body: @MainActor (Engine, UUID, CustomInstrumentDef, CustomInstrumentFile) async -> ActionResult
    ) async -> ActionResult {
        await withResolvedCustomInstrumentDef(args, engine: engineMaybe) { engine, defID, def in
            guard let path = args["path"] as? String, !path.isEmpty else {
                return errorResult("missing path", code: .invalidInput)
            }
            guard let file = engine.customInstruments.file(defID: defID, path: path) else {
                return errorResult("no file '\(path)' in custom instrument \(defID)", code: .notFound)
            }
            return await body(engine, defID, def, file)
        }
    }

    private static func customInstrumentWidgetJSON(_ widget: InstrumentWidget) -> [String: Any] {
        var obj: [String: Any] = [
            "id": widget.id,
            "name": widget.name,
            "persistence": widget.persistence.rawValue,
        ]
        switch widget.kind {
        case .counter(let cfg):
            obj["kind"] = "counter"
            if let unit = cfg.unit { obj["unit"] = unit }
        case .histogram(let cfg):
            obj["kind"] = "histogram"
            obj["max_buckets"] = cfg.maxBuckets
        case .graph(let cfg):
            obj["kind"] = "graph"
            obj["series"] = cfg.series.map { ["id": $0.id, "name": $0.name] }
            obj["max_points"] = cfg.maxPoints
        case .list(let cfg):
            obj["kind"] = "list"
            obj["actions"] = cfg.actions.map { ["id": $0.id, "name": $0.name] }
            obj["max_items"] = cfg.maxItems
        case .table(let cfg):
            obj["kind"] = "table"
            obj["columns"] = cfg.columns.map { ["id": $0.id, "name": $0.name, "alignment": $0.alignment.rawValue] }
            obj["actions"] = cfg.actions.map { ["id": $0.id, "name": $0.name] }
            obj["max_rows"] = cfg.maxRows
        case .hex(let cfg):
            obj["kind"] = "hex"
            obj["max_bytes"] = cfg.maxBytes
        case .console(let cfg):
            obj["kind"] = "console"
            if let prompt = cfg.prompt { obj["prompt"] = prompt }
            if let placeholder = cfg.placeholder { obj["placeholder"] = placeholder }
            if let label = cfg.runButtonLabel { obj["run_button_label"] = label }
            obj["max_entries"] = cfg.maxEntries
        }
        return obj
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
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let title = invocation.args["title"] as? String,
                let body = invocation.args["body_markdown"] as? String,
                let confidenceStr = invocation.args["confidence"] as? String,
                let confidence = MissionFindingConfidence(rawValue: confidenceStr),
                let kind = invocation.args["kind"] as? String,
                let evidenceList = invocation.args["evidence"] as? [[String: Any]],
                !evidenceList.isEmpty
            else {
                return errorResult("invalid arguments — title, body_markdown, confidence, kind, and non-empty evidence are required", code: .invalidInput)
            }

            let actions = (try? engine.store.fetchMissionActions(missionID: invocation.mission.id)) ?? []
            let knownToolCallIDs = Set(actions.compactMap { $0.toolCallID })

            var validatedEvidence: [(MissionEvidenceKind, [String: Any])] = []
            for entry in evidenceList {
                guard let kindStr = entry["kind"] as? String,
                    let evKind = MissionEvidenceKind(rawValue: kindStr),
                    let ref = entry["ref"] as? [String: Any]
                else {
                    return errorResult("evidence entry malformed: \(entry)", code: .invalidInput)
                }

                if evKind == .action {
                    guard let cid = ref["tool_call_id"] as? String,
                        knownToolCallIDs.contains(cid)
                    else {
                        return errorResult("evidence references unknown tool_call_id; this finding is not grounded", code: .invalidInput)
                    }
                }
                validatedEvidence.append((evKind, ref))
            }

            let sessionID = parseSessionID(invocation.args)
            let finding = MissionFinding(
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

    private static func registerListFindings(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_findings",
            description: "List findings recorded during this mission. Returns id, title, confidence, kind, status, session_id, and created_at. Use to remember what you've already grounded so you don't double-record.",
            inputSchemaJSON: """
                {"type":"object","properties":{"status":{"type":"string","enum":["proposed","accepted","refuted","superseded"]},"confidence":{"type":"string","enum":["low","medium","high"]},"limit":{"type":"integer","minimum":1,"maximum":500,"description":"Max results (default 100)"}},"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            let limit = (invocation.args["limit"] as? Int) ?? 100
            let statusFilter = (invocation.args["status"] as? String).flatMap(MissionFindingStatus.init(rawValue:))
            let confidenceFilter = (invocation.args["confidence"] as? String).flatMap(MissionFindingConfidence.init(rawValue:))
            let findings = (try? engine.store.fetchMissionFindings(missionID: invocation.mission.id)) ?? []
            let filtered = findings.filter { f in
                (statusFilter == nil || f.status == statusFilter) &&
                (confidenceFilter == nil || f.confidence == confidenceFilter)
            }
            let array = filtered.suffix(limit).map(findingSummaryJSON)
            return makeResult(jsonObject: Array(array), summary: "\(array.count) finding\(array.count == 1 ? "" : "s")")
        }
    }

    private static func findingSummaryJSON(_ finding: MissionFinding) -> [String: Any] {
        var obj: [String: Any] = [
            "finding_id": finding.id.uuidString,
            "title": finding.title,
            "confidence": finding.confidence.rawValue,
            "kind": finding.kind,
            "status": finding.status.rawValue,
            "created_at": ISO8601DateFormatter().string(from: finding.createdAt),
        ]
        if let sessionID = finding.sessionID {
            obj["session_id"] = sessionID.uuidString
        }
        return obj
    }

    private static func registerReadFinding(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_finding",
            description: "Read the full body and evidence list for a finding. Use after list_findings to fetch markdown and the evidence references that grounded the claim.",
            inputSchemaJSON: """
                {"type":"object","properties":{"finding_id":{"type":"string"}},"required":["finding_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: false
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine else { return errorResult("engine unavailable", code: .unavailable) }
            guard let idString = invocation.args["finding_id"] as? String,
                let findingID = UUID(uuidString: idString)
            else {
                return errorResult("missing or invalid finding_id", code: .invalidInput)
            }
            let findings = (try? engine.store.fetchMissionFindings(missionID: invocation.mission.id)) ?? []
            guard let finding = findings.first(where: { $0.id == findingID }) else {
                return errorResult("no finding with id \(findingID)", code: .notFound)
            }
            let evidence = (try? engine.store.fetchMissionEvidence(findingID: findingID)) ?? []
            var obj = findingSummaryJSON(finding)
            obj["body_markdown"] = finding.bodyMarkdown
            obj["evidence"] = evidence.map(evidenceJSON)
            return makeResult(jsonObject: obj, summary: "Read finding \"\(finding.title)\"")
        }
    }

    private static func evidenceJSON(_ evidence: MissionEvidence) -> [String: Any] {
        var obj: [String: Any] = ["kind": evidence.kind.rawValue]
        if let data = evidence.refJSON.data(using: .utf8),
            let ref = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            obj["ref"] = ref
        }
        return obj
    }

    // MARK: - r2_cmd

    private static func registerR2Cmd(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "r2_cmd",
            description: "Run a radare2 command in this session's r2 context and return its stdout. Use for ad-hoc queries the typed tools don't cover (e.g. axt for xrefs, izz~pattern for strings, iiq for imports, afi for function info). The r2 instance analyses the target process via Frida-backed memory IO; commands cannot affect the live process. Output is truncated to max_output_chars.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"command":{"type":"string","description":"r2 command line, e.g. 'axt @ 0x1004500' or 'izz~http'"},"max_output_chars":{"type":"integer","minimum":256,"maximum":262144,"default":32768}},"required":["session_id","command"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let command = (invocation.args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !command.isEmpty
            else {
                return errorResult("missing or empty command", code: .invalidInput)
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            let limit = (invocation.args["max_output_chars"] as? Int) ?? 32_768
            let result = await dis.runCommand(command)
            let (text, wasTruncated) = truncated(result.output ?? "", to: limit)
            var payload: [String: Any] = ["command": command, "output": text]
            if wasTruncated {
                payload["truncated"] = true
                payload["original_chars"] = (result.output ?? "").count
            }
            if !result.logs.isEmpty {
                payload["logs"] = result.logs.map(logEntryToJSON)
            }
            let suffix = result.hasErrors ? " (errors)" : (wasTruncated ? " (truncated)" : "")
            return makeResult(jsonObject: payload, summary: "r2: \(command)\(suffix)")
        }
    }

    private static func logEntryToJSON(_ entry: R2LogEntry) -> [String: Any] {
        var obj: [String: Any] = [
            "level": logLevelName(entry.level),
            "message": entry.message,
        ]
        if let origin = entry.origin {
            obj["origin"] = origin
        }
        return obj
    }

    private static func logLevelName(_ level: R2LogLevel) -> String {
        switch level {
        case .fatal: return "fatal"
        case .error: return "error"
        case .warn: return "warn"
        case .info: return "info"
        case .todo: return "todo"
        case .debug: return "debug"
        case .trace: return "trace"
        }
    }

    private static func truncated(_ text: String, to limit: Int) -> (String, Bool) {
        if text.count <= limit {
            return (text, false)
        }
        let head = text.prefix(limit)
        return (head + "\n[truncated]", true)
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
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            let text = await dis.decompile(at: address).output ?? ""
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
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            let focus = (invocation.args["focus"] as? String) ?? ""

            let lines = await dis.disassemble(DisassemblyRequest(address: address, count: 64, appearance: .light))
            let disasmText = lines.map { line in
                String(format: "0x%llx", line.address) + "  " + line.asmText.plainText
            }.joined(separator: "\n")
            let decompText = await dis.decompile(at: address).output ?? ""

            let system = "You are a concise reverse-engineering assistant. Given disassembly and a pseudo-decompile of a function, produce a 2-4 sentence explanation of what the function does. Be specific about what the function reads/writes/calls. Do not restate the input."
            var user = "Address: \(addrString)\n\nDisassembly:\n\(disasmText)\n\nPseudo-C:\n\(decompText)\n"
            if !focus.isEmpty {
                user += "\nFocus on: \(focus)\n"
            }

            let outcome = await runLLMQuery(
                engine: engine,
                providerID: invocation.mission.providerID,
                modelID: invocation.mission.modelID,
                system: system,
                user: user
            )

            switch outcome {
            case .success(let explanation):
                let payload: [String: Any] = ["address": addrString, "explanation": explanation]
                return makeResult(jsonObject: payload, summary: "Explained function at \(addrString)")
            case .failure(let reason):
                return errorResult("explanation failed: \(reason)")
            }
        }
    }

    // MARK: - suggest_function_name

    private static func registerSuggestFunctionName(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "suggest_function_name",
            description: "Propose a better name for a function based on its callers, callees, strings, and decompile. Returns a proposal only — does not rename anything in the project. The agent can choose to apply it via r2_cmd with the suggested `afn` line.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address of function start"}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            let hex = String(address, radix: 16)
            _ = await dis.runCommand("af @ 0x\(hex)")
            let xrefs = await dis.runCommand("axff~$[3] @ 0x\(hex)").output ?? ""
            let nearby = await dis.runCommand("fd. @ 0x\(hex)").output ?? ""
            let decomp = await dis.decompile(at: address).output ?? ""

            let system = "You suggest concise, descriptive function names for reverse-engineered binaries. Output exactly one line: an `afn NEWNAME` r2 command. NEWNAME must be a single alphanumeric/underscore identifier. No prose, no markdown."
            let user = "Address: \(addrString)\n\nCallees / xrefs:\n\(xrefs)\n\nNearby flags:\n\(nearby)\n\nPseudo-C:\n\(decomp)\n"

            let outcome = await runLLMQuery(
                engine: engine,
                providerID: invocation.mission.providerID,
                modelID: invocation.mission.modelID,
                system: system,
                user: user
            )
            switch outcome {
            case .success(let line):
                let payload: [String: Any] = ["address": addrString, "afn_command": line]
                return makeResult(jsonObject: payload, summary: "Name suggestion for \(addrString)")
            case .failure(let reason):
                return errorResult("name suggestion failed: \(reason)")
            }
        }
    }

    // MARK: - suggest_function_signature

    private static func registerSuggestFunctionSignature(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "suggest_function_signature",
            description: "Propose an improved C-style signature for a function based on argument/return usage. Returns a proposal only — does not modify the project.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address of function start"}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            let hex = String(address, radix: 16)
            _ = await dis.runCommand("af @ 0x\(hex)")
            let vars = await dis.runCommand("afv @ 0x\(hex)").output ?? ""
            let current = await dis.runCommand("afs @ 0x\(hex)").output ?? ""
            let decomp = await dis.decompile(at: address).output ?? ""

            let system = "You infer C function signatures from low-level analysis. Output exactly one line: an `afs SIGNATURE` r2 command. Do NOT print the function body. No prose, no markdown."
            let user = "Variables:\n\(vars)\n\nCurrent signature:\n\(current)\n\nPseudo-C:\n\(decomp)\n"

            let outcome = await runLLMQuery(
                engine: engine,
                providerID: invocation.mission.providerID,
                modelID: invocation.mission.modelID,
                system: system,
                user: user
            )
            switch outcome {
            case .success(let line):
                let payload: [String: Any] = ["address": addrString, "afs_command": line]
                return makeResult(jsonObject: payload, summary: "Signature suggestion for \(addrString)")
            case .failure(let reason):
                return errorResult("signature suggestion failed: \(reason)")
            }
        }
    }

    // MARK: - suggest_local_names

    private static func registerSuggestLocalNames(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "suggest_local_names",
            description: "Propose better names and types for local variables and arguments of a function. Returns an r2 script of `afvn`/`afvt` commands — the agent can apply them via r2_cmd.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address of function start"}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            let hex = String(address, radix: 16)
            _ = await dis.runCommand("af @ 0x\(hex)")
            let vars = await dis.runCommand("afv @ 0x\(hex)").output ?? ""
            let decomp = await dis.decompile(at: address).output ?? ""

            let system = "You rename local variables and arguments based on how they're used. Output an r2 script of `afvn` (rename) and `afvt` (retype) commands, one per line. No prose, no markdown."
            let user = "Variables:\n\(vars)\n\nPseudo-C:\n\(decomp)\n"

            let outcome = await runLLMQuery(
                engine: engine,
                providerID: invocation.mission.providerID,
                modelID: invocation.mission.modelID,
                system: system,
                user: user
            )
            switch outcome {
            case .success(let script):
                let payload: [String: Any] = ["address": addrString, "script": script]
                return makeResult(jsonObject: payload, summary: "Local-name suggestions for \(addrString)")
            case .failure(let reason):
                return errorResult("local-name suggestion failed: \(reason)")
            }
        }
    }

    // MARK: - find_vulnerabilities

    private static func registerFindVulnerabilities(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "find_vulnerabilities",
            description: "Inspect a function's pseudo-decompile for likely vulnerabilities or bugs. Returns a short analysis with suggested mitigations and, where relevant, a sketched exploit. Heuristic — verify before recording findings.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"address":{"type":"string","description":"Hex address of function start"}},"required":["session_id","address"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let addrString = invocation.args["address"] as? String,
                let address = parseHexAddress(addrString)
            else {
                return errorResult("missing or invalid address", code: .invalidInput)
            }
            guard let dis = engine.disassembler(forSessionID: sessionID) else {
                return errorResult("no disassembler for session", code: .notFound)
            }
            let decomp = await dis.decompile(at: address).output ?? ""

            let system = "You are a security analyst. Given a function's pseudo-decompile, identify likely vulnerabilities or bugs. Do not show the input code. Produce a short analysis with: (1) findings, (2) suggested mitigations, (3) a brief exploit sketch where relevant."
            let user = "Address: \(addrString)\n\nPseudo-C:\n\(decomp)\n"

            let outcome = await runLLMQuery(
                engine: engine,
                providerID: invocation.mission.providerID,
                modelID: invocation.mission.modelID,
                system: system,
                user: user,
                maxOutputTokens: 2048
            )
            switch outcome {
            case .success(let analysis):
                let payload: [String: Any] = ["address": addrString, "analysis": analysis]
                return makeResult(jsonObject: payload, summary: "Vulnerability analysis for \(addrString)")
            case .failure(let reason):
                return errorResult("vulnerability analysis failed: \(reason)")
            }
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
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let findingIDString = invocation.args["finding_id"] as? String,
                let findingID = UUID(uuidString: findingIDString),
                var finding = (try? engine.store.fetchMissionFindings(missionID: invocation.mission.id))?.first(where: { $0.id == findingID })
            else {
                return errorResult("finding_id does not match a finding in this mission", code: .invalidInput)
            }

            let kindString = (invocation.args["kind"] as? String) ?? "disassembly"
            let insightKind: AddressInsight.Kind = kindString == "memory" ? .memory : .disassembly

            let anchor: AddressAnchor
            if let anchorObj = invocation.args["anchor"] as? [String: Any] {
                do {
                    anchor = try AddressAnchor.fromJSON(anchorObj)
                } catch {
                    return errorResult("anchor parse failed: \(error.localizedDescription)", code: .invalidInput)
                }
            } else if let addrString = invocation.args["address"] as? String, let address = parseHexAddress(addrString) {
                guard let node = engine.node(forSessionID: sessionID) else {
                    return errorResult("no attached session for id \(sessionID)", code: .notFound)
                }
                anchor = node.anchor(for: address)
            } else {
                return errorResult("must supply either 'address' or 'anchor'", code: .invalidInput)
            }

            let title = (invocation.args["title"] as? String) ?? finding.title
            let insight = AddressInsight(sessionID: sessionID, userTitle: title, kind: insightKind, anchor: anchor)

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

    // MARK: - list_address_insights / unpin_insight

    private static func registerListAddressInsights(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "list_address_insights",
            description: "List the address insights pinned in this session: id, kind (memory or disassembly), title, anchor display, byte count, and last resolved address. Use to revisit prior pins or pick stale ones for unpin_insight.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            let insights = engine.insightsBySession[sessionID] ?? []
            let array: [[String: Any]] = insights.map { addressInsightJSON($0, engine: engine) }
            return makeResult(jsonObject: array, summary: "\(array.count) insight\(array.count == 1 ? "" : "s")")
        }
    }

    private static func registerUnpinInsight(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "unpin_insight",
            description: "Remove a pinned address insight from the session sidebar. The underlying finding stays; only the persistent pin is removed.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"insight_id":{"type":"string"}},"required":["session_id","insight_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let idString = invocation.args["insight_id"] as? String,
                let insightID = UUID(uuidString: idString)
            else {
                return errorResult("missing or invalid insight_id", code: .invalidInput)
            }
            guard (engine.insightsBySession[sessionID] ?? []).contains(where: { $0.id == insightID }) else {
                return errorResult("no insight \(insightID) on session \(sessionID)", code: .notFound)
            }
            engine.deleteInsight(id: insightID, sessionID: sessionID)
            let payload: [String: Any] = ["insight_id": insightID.uuidString, "removed": true]
            return makeResult(jsonObject: payload, summary: "Unpinned insight \(insightID.uuidString.prefix(8))")
        }
    }

    private static func registerRenameInsight(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "rename_insight",
            description: "Rename a pinned address insight. Use after you've inferred what a routine does — give it a meaningful name so the new title shows in the sidebar and as an r2 flag (and as the function name if the insight sits on a function start). Keep names short, lowercase, snake or camel.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"insight_id":{"type":"string"},"title":{"type":"string","minLength":1}},"required":["session_id","insight_id","title"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let idString = invocation.args["insight_id"] as? String,
                let insightID = UUID(uuidString: idString)
            else {
                return errorResult("missing or invalid insight_id", code: .invalidInput)
            }
            guard let raw = invocation.args["title"] as? String else {
                return errorResult("missing title", code: .invalidInput)
            }
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return errorResult("title must be non-empty", code: .invalidInput)
            }
            guard let insight = (engine.insightsBySession[sessionID] ?? []).first(where: { $0.id == insightID }) else {
                return errorResult("no insight \(insightID) on session \(sessionID)", code: .notFound)
            }
            engine.renameInsight(insight, to: title)
            let payload: [String: Any] = ["insight_id": insightID.uuidString, "title": title]
            return makeResult(jsonObject: payload, summary: "Renamed insight to \"\(title)\"")
        }
    }

    private static func registerReadWidgetState(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "read_widget_state",
            description: "Read the current cached state of a widget on a running instrument instance. Returns graph series points, list items, table rows, counter value, histogram buckets, hex bytes (base64), or console entries — whichever the widget is. Console image entries are delivered as image attachments; pass `image_options.max_dimension` (longest edge, default 1568, min 64) to cap resolution and token cost.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"instance_id":{"type":"string"},"widget":{"type":"string"},"image_options":{"type":"object","properties":{"max_dimension":{"type":"integer","minimum":64,"default":1568,"description":"Longest edge in pixels. Larger images are scaled down before being returned as attachments."}},"additionalProperties":false}},"required":["session_id","instance_id","widget"],"additionalProperties":false}
                """,
            isObserve: true,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, parseSessionID(invocation.args) != nil else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let instanceIDStr = invocation.args["instance_id"] as? String,
                let instanceID = UUID(uuidString: instanceIDStr)
            else {
                return errorResult("missing or invalid instance_id", code: .invalidInput)
            }
            guard let widgetID = invocation.args["widget"] as? String, !widgetID.isEmpty else {
                return errorResult("missing widget", code: .invalidInput)
            }
            let maxDimension = parseImageMaxDimension(invocation.args["image_options"])
            let state = engine.widgetState(instanceID: instanceID, widget: widgetID)
            let (payload, attachments) = widgetStatePayload(
                state,
                imageProcessor: engine.imageProcessor,
                maxDimension: maxDimension
            )
            return makeResult(
                jsonObject: payload,
                attachments: attachments,
                summary: "Read state of widget \(widgetID)"
            )
        }
    }

    private static let defaultImageMaxDimension = 1568

    private static func parseImageMaxDimension(_ raw: Any?) -> Int {
        guard let obj = raw as? [String: Any],
            let value = obj["max_dimension"] as? Int,
            value >= 64
        else { return defaultImageMaxDimension }
        return value
    }

    private static func widgetStatePayload(
        _ state: WidgetState,
        imageProcessor: ImageProcessor?,
        maxDimension: Int
    ) -> (payload: [String: Any], attachments: [LLMAttachment]) {
        var points: [[String: Any]] = []
        for (seriesID, seriesPoints) in state.graphSeries {
            for point in seriesPoints {
                points.append(["series": seriesID, "x": point.x, "y": point.y])
            }
        }
        let items = state.listItems.map { item -> [String: Any] in
            var obj: [String: Any] = ["id": item.id, "title": item.title]
            if let s = item.subtitle { obj["subtitle"] = s }
            if let a = item.accessory { obj["accessory"] = a }
            return obj
        }
        let rows = state.tableRows.map { row -> [String: Any] in
            ["id": row.id, "cells": row.cells]
        }
        let buckets = state.histogram.map { ["label": $0.label, "count": $0.count] }

        var attachments: [LLMAttachment] = []
        let consoleEntries = state.consoleEntries.map { entry -> [String: Any] in
            consoleEntryPayload(
                entry,
                imageProcessor: imageProcessor,
                maxDimension: maxDimension,
                attachments: &attachments
            )
        }

        var obj: [String: Any] = [
            "points": points,
            "items": items,
            "rows": rows,
            "buckets": buckets,
            "entries": consoleEntries,
        ]
        if let counter = state.counter {
            var counterObj: [String: Any] = ["value": counter.value]
            if let unit = counter.unit { counterObj["unit"] = unit }
            if let delta = counter.delta { counterObj["delta"] = delta }
            obj["counter"] = counterObj
        }
        if let hex = state.hex {
            obj["hex"] = [
                "bytes": hex.bytes.base64EncodedString(),
                "base_address": String(format: "0x%llx", hex.baseAddress),
            ]
        }
        return (obj, attachments)
    }

    private static func consoleEntryPayload(
        _ entry: WidgetConsoleEntry,
        imageProcessor: ImageProcessor?,
        maxDimension: Int,
        attachments: inout [LLMAttachment]
    ) -> [String: Any] {
        var obj: [String: Any] = [
            "id": entry.id,
            "kind": entry.kind.rawValue,
            "text": entry.text,
        ]
        if let replyTo = entry.replyTo { obj["reply_to"] = replyTo }
        if let image = entry.image {
            let attachmentID = "attachment-\(attachments.count + 1)"
            let processed = imageProcessor?.scaleDown(
                data: image.data,
                mediaType: image.mediaType,
                maxDimension: maxDimension
            )
            let delivered = processed ?? ProcessedImage(
                mediaType: image.mediaType,
                data: image.data,
                width: image.width,
                height: image.height
            )
            attachments.append(LLMAttachment(
                kind: .image,
                mediaType: delivered.mediaType,
                base64: delivered.data.base64EncodedString()
            ))
            obj["image"] = [
                "attachment_id": attachmentID,
                "media_type": delivered.mediaType,
                "width": delivered.width,
                "height": delivered.height,
                "original_width": image.width,
                "original_height": image.height,
            ]
        }
        return obj
    }

    private static func registerInvokeWidgetAction(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "invoke_widget_action",
            description: "Trigger a widget action (declared on a list or table widget). The instrument's onAction handler runs server-side. Use to programmatically click an action button on a row your instrument has surfaced.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"instance_id":{"type":"string"},"widget":{"type":"string"},"action":{"type":"string"},"item":{"type":"string","description":"Optional row/item id the action targets"}},"required":["session_id","instance_id","widget","action"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let instanceIDStr = invocation.args["instance_id"] as? String,
                let instanceID = UUID(uuidString: instanceIDStr)
            else {
                return errorResult("missing or invalid instance_id", code: .invalidInput)
            }
            guard let widget = invocation.args["widget"] as? String, !widget.isEmpty,
                let action = invocation.args["action"] as? String, !action.isEmpty
            else {
                return errorResult("missing widget or action", code: .invalidInput)
            }
            let instance: InstrumentInstance
            switch resolveLiveInstrument(engine: engine, sessionID: sessionID, instanceID: instanceID) {
            case .found(let live): instance = live.instance
            case .error(let err): return err
            }
            let item = invocation.args["item"] as? String
            await engine.invokeWidgetAction(instance: instance, widget: widget, action: action, item: item)
            var payload: [String: Any] = [
                "instance_id": instanceID.uuidString,
                "widget": widget,
                "action": action,
            ]
            if let item { payload["item"] = item }
            return makeResult(jsonObject: payload, summary: "Invoked \(action) on \(widget)")
        }
    }

    private static func registerSubmitConsoleInput(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "submit_console_input",
            description: "Send a line of input to a console widget and wait for the instrument's responses (entries posted with `respond.output` / `respond.error` / `respond.value` from `onConsoleInput`). Returns whatever responses arrived within `timeout_ms` (default 2000). Free-form output the instrument emits via appendOutput / appendError / appendValue is NOT included — only entries explicitly tied back to this input.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"},"instance_id":{"type":"string"},"widget":{"type":"string"},"text":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1,"maximum":60000,"default":2000}},"required":["session_id","instance_id","widget","text"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard let instanceIDStr = invocation.args["instance_id"] as? String,
                let instanceID = UUID(uuidString: instanceIDStr)
            else {
                return errorResult("missing or invalid instance_id", code: .invalidInput)
            }
            guard let widget = invocation.args["widget"] as? String, !widget.isEmpty else {
                return errorResult("missing widget", code: .invalidInput)
            }
            guard let text = invocation.args["text"] as? String else {
                return errorResult("missing text", code: .invalidInput)
            }
            let instance: InstrumentInstance
            switch resolveLiveInstrument(engine: engine, sessionID: sessionID, instanceID: instanceID) {
            case .found(let live): instance = live.instance
            case .error(let err): return err
            }
            let timeoutMs = (invocation.args["timeout_ms"] as? Int) ?? 2000
            let response = await engine.submitConsoleInputAndAwait(
                instance: instance,
                widget: widget,
                text: text,
                timeout: .milliseconds(timeoutMs)
            )
            let replies = response.replies.map(consoleEntryJSON)
            let payload: [String: Any] = [
                "instance_id": instanceID.uuidString,
                "widget": widget,
                "input_entry_id": response.inputEntryID,
                "replies": replies,
            ]
            return makeResult(jsonObject: payload, summary: "Submitted to \(widget), \(replies.count) repl\(replies.count == 1 ? "y" : "ies")")
        }
    }

    private static func consoleEntryJSON(_ entry: WidgetConsoleEntry) -> [String: Any] {
        entry.toWireJSON()
    }

    private struct LiveInstrument {
        let instance: InstrumentInstance
        let node: ProcessNode
        let ref: ProcessNode.InstrumentRef
    }

    private enum LiveInstrumentLookup {
        case found(LiveInstrument)
        case error(ActionResult)
    }

    private static func resolveLiveInstrument(
        engine: Engine,
        sessionID: UUID,
        instanceID: UUID
    ) -> LiveInstrumentLookup {
        guard let session = engine.sessions.first(where: { $0.id == sessionID }) else {
            return .error(errorResult("no session with id \(sessionID)", code: .notFound))
        }
        guard let node = engine.node(forSessionID: sessionID) else {
            return .error(errorResult(
                "session \(sessionID) is not attached (phase=\(phaseDescription(session.phase)))",
                code: .unavailable
            ))
        }
        guard let instance = engine.instrumentsBySession[sessionID]?.first(where: { $0.id == instanceID }) else {
            return .error(errorResult("no instrument \(instanceID) on session \(sessionID)", code: .notFound))
        }
        guard let ref = node.instruments.first(where: { $0.id == instanceID }), ref.attachment == .attached else {
            return .error(errorResult(
                "instrument \(instanceID) is not attached on session \(sessionID) — recompile may have failed",
                code: .unavailable
            ))
        }
        if let status = ref.status {
            return .error(errorResult(
                "instrument \(instanceID) is in error state: \(status.summary)",
                code: .unavailable
            ))
        }
        return .found(LiveInstrument(instance: instance, node: node, ref: ref))
    }

    private static func registerDetachSession(in catalog: ToolCatalog, engine: Engine) {
        let spec = ActionSpec(
            name: "detach_session",
            description: "Drop a session entirely: detach Frida, dispose any attached instruments, and remove the session record from the project. Use to clean up sessions you created when a mission is finishing. Requires user approval.",
            inputSchemaJSON: """
                {"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"],"additionalProperties":false}
                """,
            isObserve: false,
            requiresSession: true
        )
        catalog.register(spec: spec) { [weak engine] invocation in
            guard let engine, let sessionID = parseSessionID(invocation.args) else {
                return errorResult("missing or invalid session_id", code: .invalidInput)
            }
            guard engine.sessions.contains(where: { $0.id == sessionID }) else {
                return errorResult("no session with id \(sessionID)", code: .notFound)
            }
            engine.deleteSession(id: sessionID)
            let payload: [String: Any] = ["session_id": sessionID.uuidString, "removed": true]
            return makeResult(jsonObject: payload, summary: "Detached session \(sessionID.uuidString.prefix(8))")
        }
    }

    private static func addressInsightJSON(_ insight: AddressInsight, engine: Engine) -> [String: Any] {
        var obj: [String: Any] = [
            "id": insight.id.uuidString,
            "title": engine.displayTitle(for: insight),
            "kind": insight.kind == .disassembly ? "disassembly" : "memory",
            "anchor": insight.anchor.displayString,
            "byte_count": insight.byteCount,
            "created_at": ISO8601DateFormatter().string(from: insight.createdAt),
        ]
        if let addr = insight.lastResolvedAddress {
            obj["last_resolved_address"] = String(format: "0x%llx", addr)
        }
        return obj
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
            errorResult("request_user_input must be answered via the Action Queue, not approved directly", code: .rejected)
        }
    }

    // MARK: - helpers

    private static func lineCount(of content: String) -> Int {
        if content.isEmpty { return 0 }
        var count = content.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if !content.hasSuffix("\n") { count += 1 }
        return count
    }

    private static func numberedContent(_ content: String) -> String {
        if content.isEmpty { return "" }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if content.hasSuffix("\n") {
            lines.removeLast()
        }
        let width = max(4, String(lines.count).count)
        var result = ""
        result.reserveCapacity(content.count + lines.count * (width + 2))
        for (index, line) in lines.enumerated() {
            let n = String(index + 1)
            let pad = String(repeating: " ", count: width - n.count)
            result += pad + n + "\t" + line + "\n"
        }
        return result
    }

    private enum SpliceOutcome {
        case success(String)
        case failure(String)
    }

    private static func spliceLines(in content: String, startLine: Int, endLine: Int, replacement: String) -> SpliceOutcome {
        let hasTrailingNewline = content.hasSuffix("\n")
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasTrailingNewline, !lines.isEmpty {
            lines.removeLast()
        }
        let total = lines.count
        if startLine < 1 || startLine > total + 1 {
            return .failure("start_line \(startLine) out of range (file has \(total) line\(total == 1 ? "" : "s"))")
        }
        if endLine < startLine - 1 || endLine > total {
            return .failure("end_line \(endLine) out of range for start_line \(startLine) (file has \(total) line\(total == 1 ? "" : "s"))")
        }
        var insertion = replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if replacement.hasSuffix("\n"), !insertion.isEmpty {
            insertion.removeLast()
        }
        lines.replaceSubrange((startLine - 1)..<endLine, with: insertion)
        let joined = lines.joined(separator: "\n")
        let needsTrailingNewline = hasTrailingNewline || !replacement.isEmpty
        return .success(needsTrailingNewline && !joined.hasSuffix("\n") ? joined + "\n" : joined)
    }

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

    private static func parseHexBytes(_ s: String) -> [UInt8]? {
        let trimmed = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
        guard trimmed.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func makeResult(
        jsonObject: Any,
        attachments: [LLMAttachment] = [],
        summary: String
    ) -> ActionResult {
        let scrubbed = truncatingOversizedStrings(jsonObject, cap: stringValueByteCap)
        guard JSONSerialization.isValidJSONObject(scrubbed) else {
            let offender = describeNonJSONValue(scrubbed) ?? "unknown"
            return errorResult("internal: tool produced non-JSON value (\(offender))")
        }
        let data = (try? JSONSerialization.data(withJSONObject: scrubbed, options: [.sortedKeys])) ?? Data("{}".utf8)
        var json = String(data: data, encoding: .utf8) ?? "{}"
        if json.utf8.count > resultByteCap {
            json = String(json.prefix(resultByteCap))
            json += "\n/* truncated — request a narrower view */"
        }
        return ActionResult(summary: summary, resultJSON: json, attachments: attachments)
    }

    private static func describeNonJSONValue(_ value: Any, path: String = "$") -> String? {
        if let dict = value as? [String: Any] {
            for (k, v) in dict {
                if let hit = describeNonJSONValue(v, path: "\(path).\(k)") {
                    return hit
                }
            }
            return nil
        }
        if let arr = value as? [Any] {
            for (i, v) in arr.enumerated() {
                if let hit = describeNonJSONValue(v, path: "\(path)[\(i)]") {
                    return hit
                }
            }
            return nil
        }
        if JSONSerialization.isValidJSONObject([value]) { return nil }
        return "\(path)=<\(type(of: value))>"
    }

    private static func truncatingOversizedStrings(_ value: Any, cap: Int) -> Any {
        if let str = value as? String {
            let byteCount = str.utf8.count
            if byteCount <= cap { return str }
            let head = String(decoding: str.utf8.prefix(cap), as: UTF8.self)
            return "\(head)… <truncated; original \(byteCount) bytes>"
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { truncatingOversizedStrings($0, cap: cap) }
        }
        if let arr = value as? [Any] {
            return arr.map { truncatingOversizedStrings($0, cap: cap) }
        }
        return value
    }

    private static func errorResult(_ message: String, code: ToolErrorCode = .failed) -> ActionResult {
        let json = "{\"error\":\"\(escapeJSON(message))\",\"code\":\"\(code.rawValue)\"}"
        return ActionResult(summary: message, resultJSON: json, isError: true)
    }

    private enum ToolErrorCode: String {
        case invalidInput = "invalid_input"
        case notFound = "not_found"
        case unavailable = "unavailable"
        case rejected = "rejected"
        case failed = "failed"
    }

    private enum LLMQueryOutcome {
        case success(String)
        case failure(String)
    }

    private static func runLLMQuery(
        engine: Engine,
        providerID: String,
        modelID: String,
        system: String,
        user: String,
        maxOutputTokens: Int = 1024,
        temperature: Double = 0.2
    ) async -> LLMQueryOutcome {
        guard let provider = engine.llmRegistry.provider(id: providerID) else {
            return .failure("provider \(providerID) not registered")
        }
        let apiKey = (try? await engine.llmCredentials.apiKey(providerID: providerID)) ?? nil
        if provider.descriptor.capabilities.supports(.apiKey), apiKey == nil {
            return .failure("missing API key for provider \(providerID)")
        }

        let request = LLMTurnRequest(
            modelID: modelID,
            systemBlocks: [LLMContentBlock(content: .text(system), cacheBoundary: true)],
            messages: [LLMMessage(role: .user, blocks: [.text(user)])],
            tools: [],
            maxOutputTokens: maxOutputTokens,
            thinkingBudget: 0,
            temperature: temperature
        )

        var output = ""
        do {
            let baseURL = LumaAppState.shared.providerBaseURL(providerID: providerID).flatMap(URL.init(string:))
            for try await event in provider.streamTurn(request, apiKey: apiKey, baseURL: baseURL) {
                if case .finalMessage(_, let blocks) = event {
                    for block in blocks {
                        if case .text(let t) = block.content {
                            output += t
                        }
                    }
                }
            }
        } catch {
            return .failure(error.localizedDescription)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure("model returned empty response")
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
        case .engine(let subsystem): return "engine:\(subsystem)"
        }
    }

    private static func describeEventSummary(_ event: RuntimeEvent) -> String {
        switch event.payload {
        case .consoleMessage(let msg):
            return msg.description
        case .jsError(let err):
            return err.text
        case .jsValue(let value):
            if isTracerEvent(event), let tracer = Engine.parseTracerEvent(from: value) {
                return tracer.message.agentSummary()
            }
            return value.agentSummary()
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
