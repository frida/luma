import Foundation

/// A single pending mutation against a lab's sessions. Mirrors the
/// NotebookOp pattern: clients persist ops to the outbox as they happen,
/// the server deduplicates by `opID`, applies, and broadcasts the
/// authoritative result back. Session IDs are client-generated so a host
/// can attach offline and have the session announced on reconnect.
public enum SessionOp: Sendable {
    case add(Add)
    case updatePhase(UpdatePhase)
    case updateProcessInfo(UpdateProcessInfo)
    case updateArming(UpdateArming)
    case updateModules(UpdateModules)
    case updateModuleAnalysis(UpdateModuleAnalysis)
    case updateModuleSymbols(UpdateModuleSymbols)
    case updateThreads(UpdateThreads)
    case claimHost(ClaimHost)
    case claimDriver(ClaimDriver)
    case addReplCell(AddReplCell)
    case addInstrument(AddInstrument)
    case updateInstrument(UpdateInstrument)
    case removeInstrument(RemoveInstrument)
    case addInsight(AddInsight)
    case updateInsight(UpdateInsight)
    case removeInsight(RemoveInsight)
    case upsertTrace(UpsertTrace)
    case removeTrace(RemoveTrace)
    case traceDataProgressed(TraceDataProgressed)
    case remove(Remove)

    public var opID: UUID {
        switch self {
        case .add(let a): return a.opID
        case .updatePhase(let u): return u.opID
        case .updateProcessInfo(let u): return u.opID
        case .updateArming(let u): return u.opID
        case .updateModules(let u): return u.opID
        case .updateModuleAnalysis(let u): return u.opID
        case .updateModuleSymbols(let u): return u.opID
        case .updateThreads(let u): return u.opID
        case .claimHost(let c): return c.opID
        case .claimDriver(let c): return c.opID
        case .addReplCell(let a): return a.opID
        case .addInstrument(let a): return a.opID
        case .updateInstrument(let u): return u.opID
        case .removeInstrument(let r): return r.opID
        case .addInsight(let a): return a.opID
        case .updateInsight(let u): return u.opID
        case .removeInsight(let r): return r.opID
        case .upsertTrace(let u): return u.opID
        case .removeTrace(let r): return r.opID
        case .traceDataProgressed(let t): return t.opID
        case .remove(let r): return r.opID
        }
    }

    public var sessionID: UUID {
        switch self {
        case .add(let a): return a.sessionID
        case .updatePhase(let u): return u.sessionID
        case .updateProcessInfo(let u): return u.sessionID
        case .updateArming(let u): return u.sessionID
        case .updateModules(let u): return u.sessionID
        case .updateModuleAnalysis(let u): return u.sessionID
        case .updateModuleSymbols(let u): return u.sessionID
        case .updateThreads(let u): return u.sessionID
        case .claimHost(let c): return c.sessionID
        case .claimDriver(let c): return c.sessionID
        case .addReplCell(let a): return a.sessionID
        case .addInstrument(let a): return a.sessionID
        case .updateInstrument(let u): return u.sessionID
        case .removeInstrument(let r): return r.sessionID
        case .addInsight(let a): return a.sessionID
        case .updateInsight(let u): return u.sessionID
        case .removeInsight(let r): return r.sessionID
        case .upsertTrace(let u): return u.sessionID
        case .removeTrace(let r): return r.sessionID
        case .traceDataProgressed(let t): return t.sessionID
        case .remove(let r): return r.sessionID
        }
    }

    public var kind: String {
        switch self {
        case .add: return "add"
        case .updatePhase: return "update-phase"
        case .updateProcessInfo: return "update-process-info"
        case .updateArming: return "update-arming"
        case .updateModules: return "update-modules"
        case .updateModuleAnalysis: return "update-module-analysis"
        case .updateModuleSymbols: return "update-module-symbols"
        case .updateThreads: return "update-threads"
        case .claimHost: return "claim-host"
        case .claimDriver: return "claim-driver"
        case .addReplCell: return "add-repl-cell"
        case .addInstrument: return "add-instrument"
        case .updateInstrument: return "update-instrument"
        case .removeInstrument: return "remove-instrument"
        case .addInsight: return "add-insight"
        case .updateInsight: return "update-insight"
        case .removeInsight: return "remove-insight"
        case .upsertTrace: return "upsert-trace"
        case .removeTrace: return "remove-trace"
        case .traceDataProgressed: return "trace-data-progressed"
        case .remove: return "remove"
        }
    }

    public struct Add: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let host: CollaborationSession.UserInfo
        public let deviceID: String
        public let deviceName: String
        public let pid: UInt
        public let processName: String
        public let createdAt: String

        public init(
            opID: UUID = UUID(),
            sessionID: UUID = UUID(),
            host: CollaborationSession.UserInfo,
            deviceID: String,
            deviceName: String,
            pid: UInt,
            processName: String,
            createdAt: String
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.host = host
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.pid = pid
            self.processName = processName
            self.createdAt = createdAt
        }
    }

    public struct UpdatePhase: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let phase: CollaborationSession.Session.Phase
        public let reason: String?
        public let lastSeenAt: String

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            phase: CollaborationSession.Session.Phase,
            reason: String? = nil,
            lastSeenAt: String
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.phase = phase
            self.reason = reason
            self.lastSeenAt = lastSeenAt
        }
    }

    public struct UpdateProcessInfo: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let info: ProcessSession.ProcessInfo

        public init(opID: UUID = UUID(), sessionID: UUID, info: ProcessSession.ProcessInfo) {
            self.opID = opID
            self.sessionID = sessionID
            self.info = info
        }
    }

    public struct UpdateArming: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let armingState: ProcessSession.ArmingState

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            armingState: ProcessSession.ArmingState
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.armingState = armingState
        }
    }

    public struct UpdateModuleAnalysis: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let analysis: ModuleAnalysis

        public init(opID: UUID = UUID(), sessionID: UUID, analysis: ModuleAnalysis) {
            self.opID = opID
            self.sessionID = sessionID
            self.analysis = analysis
        }
    }

    public struct UpdateModuleSymbols: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let entries: [Entry]

        public struct Entry: Sendable, Hashable {
            public let modulePath: String
            public let offset: UInt64
            public let name: String

            public init(modulePath: String, offset: UInt64, name: String) {
                self.modulePath = modulePath
                self.offset = offset
                self.name = name
            }
        }

        public init(opID: UUID = UUID(), sessionID: UUID, entries: [Entry]) {
            self.opID = opID
            self.sessionID = sessionID
            self.entries = entries
        }
    }

    public struct UpdateModules: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let delta: ModuleDelta

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            delta: ModuleDelta
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.delta = delta
        }
    }

    public struct UpdateThreads: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let delta: ThreadDelta

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            delta: ThreadDelta
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.delta = delta
        }
    }

    public struct ClaimHost: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let host: CollaborationSession.UserInfo
        public let deviceID: String
        public let deviceName: String
        public let pid: UInt
        public let processName: String

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            host: CollaborationSession.UserInfo,
            deviceID: String,
            deviceName: String,
            pid: UInt,
            processName: String
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.host = host
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.pid = pid
            self.processName = processName
        }
    }

    public struct ClaimDriver: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let driver: CollaborationSession.UserInfo

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            driver: CollaborationSession.UserInfo
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.driver = driver
        }
    }

    public struct AddReplCell: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let cell: REPLCell

        public init(opID: UUID = UUID(), sessionID: UUID, cell: REPLCell) {
            self.opID = opID
            self.sessionID = sessionID
            self.cell = cell
        }
    }

    public struct AddInstrument: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let instance: InstrumentInstance
        public let runtimeStatus: InstrumentStatus?

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            instance: InstrumentInstance,
            runtimeStatus: InstrumentStatus? = nil
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.instance = instance
            self.runtimeStatus = runtimeStatus
        }
    }

    public struct UpdateInstrument: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let instance: InstrumentInstance
        public let runtimeStatus: InstrumentStatus?

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            instance: InstrumentInstance,
            runtimeStatus: InstrumentStatus? = nil
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.instance = instance
            self.runtimeStatus = runtimeStatus
        }
    }

    public struct RemoveInstrument: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let instanceID: UUID

        public init(opID: UUID = UUID(), sessionID: UUID, instanceID: UUID) {
            self.opID = opID
            self.sessionID = sessionID
            self.instanceID = instanceID
        }
    }

    public struct AddInsight: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let insight: AddressInsight

        public init(opID: UUID = UUID(), sessionID: UUID, insight: AddressInsight) {
            self.opID = opID
            self.sessionID = sessionID
            self.insight = insight
        }
    }

    public struct UpdateInsight: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let insight: AddressInsight

        public init(opID: UUID = UUID(), sessionID: UUID, insight: AddressInsight) {
            self.opID = opID
            self.sessionID = sessionID
            self.insight = insight
        }
    }

    public struct RemoveInsight: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let insightID: UUID

        public init(opID: UUID = UUID(), sessionID: UUID, insightID: UUID) {
            self.opID = opID
            self.sessionID = sessionID
            self.insightID = insightID
        }
    }

    public struct UpsertTrace: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let trace: ITrace

        public init(opID: UUID = UUID(), sessionID: UUID, trace: ITrace) {
            self.opID = opID
            self.sessionID = sessionID
            self.trace = trace
        }
    }

    public struct TraceDataProgressed: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let traceID: UUID
        public let totalSize: Int

        public init(opID: UUID = UUID(), sessionID: UUID, traceID: UUID, totalSize: Int) {
            self.opID = opID
            self.sessionID = sessionID
            self.traceID = traceID
            self.totalSize = totalSize
        }
    }

    public struct RemoveTrace: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let traceID: UUID

        public init(opID: UUID = UUID(), sessionID: UUID, traceID: UUID) {
            self.opID = opID
            self.sessionID = sessionID
            self.traceID = traceID
        }
    }

    public struct Remove: Sendable {
        public let opID: UUID
        public let sessionID: UUID

        public init(opID: UUID = UUID(), sessionID: UUID) {
            self.opID = opID
            self.sessionID = sessionID
        }
    }

    public func toJSON() -> [String: Any] {
        var obj: [String: Any] = [
            "op_id": opID.uuidString,
            "kind": kind,
        ]
        switch self {
        case .add(let a):
            obj["host"] = [
                "id": a.host.id,
                "name": a.host.name,
                "avatar": a.host.avatarURL?.absoluteString ?? "",
            ]
            obj["device"] = ["id": a.deviceID, "name": a.deviceName]
            obj["process"] = ["pid": a.pid, "name": a.processName]
            obj["created_at"] = a.createdAt
        case .updatePhase(let u):
            obj["phase"] = u.phase.rawValue
            obj["last_seen_at"] = u.lastSeenAt
            if let reason = u.reason { obj["reason"] = reason }
        case .updateProcessInfo(let u):
            obj["info"] = [
                "platform": u.info.platform,
                "arch": u.info.arch,
                "pointer_size": u.info.pointerSize,
                "identity": u.info.identity,
            ]
        case .updateArming(let u):
            obj["arming_state"] = encodeArmingState(u.armingState)
        case .updateModules(let u):
            obj["added"] = u.delta.added.map { $0.toJSON() }
            obj["removed"] = u.delta.removed.map { $0.toJSON() }
        case .updateModuleAnalysis(let u):
            obj["analysis"] = u.analysis.toWireJSON() ?? [:]
        case .updateModuleSymbols(let u):
            obj["entries"] = u.entries.map { entry -> [String: Any] in
                [
                    "module_path": entry.modulePath,
                    "offset": Int64(bitPattern: entry.offset),
                    "name": entry.name,
                ]
            }
        case .updateThreads(let u):
            obj["added"] = u.delta.added.map { $0.toJSON() }
            obj["removed"] = u.delta.removed.map { Int($0) }
            obj["renamed"] = u.delta.renamed.map { rename -> [String: Any] in
                var entry: [String: Any] = ["id": Int(rename.id)]
                if let name = rename.name { entry["name"] = name }
                return entry
            }
        case .claimHost(let c):
            obj["host"] = [
                "id": c.host.id,
                "name": c.host.name,
                "avatar": c.host.avatarURL?.absoluteString ?? "",
            ]
            obj["device"] = ["id": c.deviceID, "name": c.deviceName]
            obj["process"] = ["pid": c.pid, "name": c.processName]
        case .claimDriver(let c):
            obj["driver"] = [
                "id": c.driver.id,
                "name": c.driver.name,
                "avatar": c.driver.avatarURL?.absoluteString ?? "",
            ]
        case .addReplCell(let a):
            if let cellObj = a.cell.toWireJSON() {
                obj["cell"] = cellObj
            }
        case .addInstrument(let a):
            if let instObj = Self.wireInstrument(instance: a.instance, runtimeStatus: a.runtimeStatus) {
                obj["instance"] = instObj
            }
        case .updateInstrument(let u):
            if let instObj = Self.wireInstrument(instance: u.instance, runtimeStatus: u.runtimeStatus) {
                obj["instance"] = instObj
            }
        case .removeInstrument(let r):
            obj["instance_id"] = r.instanceID.uuidString
        case .addInsight(let a):
            if let insightObj = a.insight.toWireJSON() {
                obj["insight"] = insightObj
            }
        case .updateInsight(let u):
            if let insightObj = u.insight.toWireJSON() {
                obj["insight"] = insightObj
            }
        case .removeInsight(let r):
            obj["insight_id"] = r.insightID.uuidString
        case .upsertTrace(let u):
            if let traceObj = u.trace.toWireJSON() {
                obj["trace"] = traceObj
            }
        case .removeTrace(let r):
            obj["trace_id"] = r.traceID.uuidString
        case .traceDataProgressed(let t):
            obj["trace_id"] = t.traceID.uuidString
            obj["total_size"] = t.totalSize
        case .remove:
            break
        }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any], sessionID: UUID) -> SessionOp? {
        guard let opIDStr = obj["op_id"] as? String,
            let opID = UUID(uuidString: opIDStr),
            let kind = obj["kind"] as? String
        else { return nil }

        switch kind {
        case "add":
            guard let hostObj = obj["host"] as? [String: Any],
                let host = CollaborationSession.UserInfo.fromJSON(hostObj),
                let deviceObj = obj["device"] as? [String: Any],
                let deviceID = deviceObj["id"] as? String,
                let deviceName = deviceObj["name"] as? String,
                let processObj = obj["process"] as? [String: Any],
                let processName = processObj["name"] as? String,
                let createdAt = obj["created_at"] as? String
            else { return nil }

            let pid: UInt
            if let v = processObj["pid"] as? Int { pid = UInt(v) }
            else if let v = processObj["pid"] as? UInt { pid = v }
            else if let v = processObj["pid"] as? NSNumber { pid = v.uintValue }
            else { return nil }

            return .add(Add(
                opID: opID,
                sessionID: sessionID,
                host: host,
                deviceID: deviceID,
                deviceName: deviceName,
                pid: pid,
                processName: processName,
                createdAt: createdAt
            ))

        case "update-phase":
            guard let phaseRaw = obj["phase"] as? String,
                let phase = CollaborationSession.Session.Phase(rawValue: phaseRaw),
                let lastSeenAt = obj["last_seen_at"] as? String
            else { return nil }
            return .updatePhase(UpdatePhase(
                opID: opID,
                sessionID: sessionID,
                phase: phase,
                reason: obj["reason"] as? String,
                lastSeenAt: lastSeenAt
            ))

        case "update-process-info":
            guard let infoObj = obj["info"] as? [String: Any],
                let platform = infoObj["platform"] as? String,
                let arch = infoObj["arch"] as? String,
                let pointerSize = infoObj["pointer_size"] as? Int,
                let identity = infoObj["identity"] as? String
            else { return nil }
            return .updateProcessInfo(UpdateProcessInfo(
                opID: opID,
                sessionID: sessionID,
                info: ProcessSession.ProcessInfo(
                    platform: platform, arch: arch, pointerSize: pointerSize, identity: identity
                )
            ))

        case "update-arming":
            guard let stateObj = obj["arming_state"] as? [String: Any],
                let armingState = decodeArmingState(stateObj)
            else { return nil }
            return .updateArming(UpdateArming(
                opID: opID,
                sessionID: sessionID,
                armingState: armingState
            ))

        case "update-module-analysis":
            guard let analysisObj = obj["analysis"] as? [String: Any],
                let analysis = ModuleAnalysis.fromWireJSON(analysisObj)
            else { return nil }
            return .updateModuleAnalysis(UpdateModuleAnalysis(
                opID: opID,
                sessionID: sessionID,
                analysis: analysis
            ))

        case "update-module-symbols":
            let raw = (obj["entries"] as? [[String: Any]]) ?? []
            let entries: [UpdateModuleSymbols.Entry] = raw.compactMap { entry in
                guard let modulePath = entry["module_path"] as? String,
                    let rawOffset = entry["offset"] as? Int64 ?? (entry["offset"] as? Int).map(Int64.init),
                    let name = entry["name"] as? String
                else { return nil }
                return UpdateModuleSymbols.Entry(
                    modulePath: modulePath,
                    offset: UInt64(bitPattern: rawOffset),
                    name: name
                )
            }
            return .updateModuleSymbols(UpdateModuleSymbols(
                opID: opID,
                sessionID: sessionID,
                entries: entries
            ))

        case "update-modules":
            let addedObjs = (obj["added"] as? [[String: Any]]) ?? []
            let removedObjs = (obj["removed"] as? [[String: Any]]) ?? []
            let added = addedObjs.compactMap(ProcessModule.fromJSON)
            let removed = removedObjs.compactMap(ProcessModule.fromJSON)
            return .updateModules(UpdateModules(
                opID: opID,
                sessionID: sessionID,
                delta: ModuleDelta(added: added, removed: removed)
            ))

        case "update-threads":
            let addedObjs = (obj["added"] as? [[String: Any]]) ?? []
            let removedIDs = (obj["removed"] as? [Int]) ?? []
            let renamedObjs = (obj["renamed"] as? [[String: Any]]) ?? []
            let added = addedObjs.compactMap(ProcessThread.fromJSON)
            let renamed = renamedObjs.compactMap { entry -> ThreadDelta.Rename? in
                guard let raw = entry["id"] as? Int else { return nil }
                return ThreadDelta.Rename(id: UInt(raw), name: entry["name"] as? String)
            }
            return .updateThreads(UpdateThreads(
                opID: opID,
                sessionID: sessionID,
                delta: ThreadDelta(
                    added: added,
                    removed: removedIDs.map { UInt($0) },
                    renamed: renamed
                )
            ))

        case "claim-host":
            guard let hostObj = obj["host"] as? [String: Any],
                let host = CollaborationSession.UserInfo.fromJSON(hostObj),
                let deviceObj = obj["device"] as? [String: Any],
                let deviceID = deviceObj["id"] as? String,
                let deviceName = deviceObj["name"] as? String,
                let processObj = obj["process"] as? [String: Any],
                let processName = processObj["name"] as? String
            else { return nil }
            let pid: UInt
            if let v = processObj["pid"] as? Int { pid = UInt(v) }
            else if let v = processObj["pid"] as? UInt { pid = v }
            else if let v = processObj["pid"] as? NSNumber { pid = v.uintValue }
            else { return nil }
            return .claimHost(ClaimHost(
                opID: opID,
                sessionID: sessionID,
                host: host,
                deviceID: deviceID,
                deviceName: deviceName,
                pid: pid,
                processName: processName
            ))

        case "claim-driver":
            guard let driverObj = obj["driver"] as? [String: Any],
                let driver = CollaborationSession.UserInfo.fromJSON(driverObj)
            else { return nil }
            return .claimDriver(ClaimDriver(
                opID: opID,
                sessionID: sessionID,
                driver: driver
            ))

        case "add-repl-cell":
            guard let cellObj = obj["cell"] as? [String: Any],
                let cell = REPLCell.fromWireJSON(cellObj)
            else { return nil }
            return .addReplCell(AddReplCell(
                opID: opID,
                sessionID: sessionID,
                cell: cell
            ))

        case "add-instrument":
            guard let instObj = obj["instance"] as? [String: Any],
                let parsed = Self.parseWireInstrument(instObj)
            else { return nil }
            return .addInstrument(AddInstrument(
                opID: opID,
                sessionID: sessionID,
                instance: parsed.instance,
                runtimeStatus: parsed.runtimeStatus
            ))

        case "update-instrument":
            guard let instObj = obj["instance"] as? [String: Any],
                let parsed = Self.parseWireInstrument(instObj)
            else { return nil }
            return .updateInstrument(UpdateInstrument(
                opID: opID,
                sessionID: sessionID,
                instance: parsed.instance,
                runtimeStatus: parsed.runtimeStatus
            ))

        case "remove-instrument":
            guard let instanceIDStr = obj["instance_id"] as? String,
                let instanceID = UUID(uuidString: instanceIDStr)
            else { return nil }
            return .removeInstrument(RemoveInstrument(
                opID: opID,
                sessionID: sessionID,
                instanceID: instanceID
            ))

        case "add-insight":
            guard let insightObj = obj["insight"] as? [String: Any],
                let insight = AddressInsight.fromWireJSON(insightObj)
            else { return nil }
            return .addInsight(AddInsight(
                opID: opID,
                sessionID: sessionID,
                insight: insight
            ))

        case "update-insight":
            guard let insightObj = obj["insight"] as? [String: Any],
                let insight = AddressInsight.fromWireJSON(insightObj)
            else { return nil }
            return .updateInsight(UpdateInsight(
                opID: opID,
                sessionID: sessionID,
                insight: insight
            ))

        case "remove-insight":
            guard let insightIDStr = obj["insight_id"] as? String,
                let insightID = UUID(uuidString: insightIDStr)
            else { return nil }
            return .removeInsight(RemoveInsight(
                opID: opID,
                sessionID: sessionID,
                insightID: insightID
            ))

        case "upsert-trace":
            guard let traceObj = obj["trace"] as? [String: Any],
                let trace = ITrace.fromWireJSON(traceObj)
            else { return nil }
            return .upsertTrace(UpsertTrace(
                opID: opID,
                sessionID: sessionID,
                trace: trace
            ))

        case "remove-trace":
            guard let traceIDStr = obj["trace_id"] as? String,
                let traceID = UUID(uuidString: traceIDStr)
            else { return nil }
            return .removeTrace(RemoveTrace(
                opID: opID,
                sessionID: sessionID,
                traceID: traceID
            ))

        case "trace-data-progressed":
            guard let traceIDStr = obj["trace_id"] as? String,
                let traceID = UUID(uuidString: traceIDStr),
                let totalSize = obj["total_size"] as? Int
            else { return nil }
            return .traceDataProgressed(TraceDataProgressed(
                opID: opID,
                sessionID: sessionID,
                traceID: traceID,
                totalSize: totalSize
            ))

        case "remove":
            return .remove(Remove(opID: opID, sessionID: sessionID))

        default:
            return nil
        }
    }

    private static func wireInstrument(instance: InstrumentInstance, runtimeStatus: InstrumentStatus?) -> [String: Any]? {
        guard var obj = instance.toWireJSON() else { return nil }
        if let runtimeStatus {
            obj["runtime_status"] = runtimeStatus.toWireJSON()
        }
        return obj
    }

    private static func parseWireInstrument(_ obj: [String: Any]) -> (instance: InstrumentInstance, runtimeStatus: InstrumentStatus?)? {
        var stripped = obj
        let statusObj = stripped.removeValue(forKey: "runtime_status") as? [String: Any]
        guard let instance = InstrumentInstance.fromWireJSON(stripped) else { return nil }
        let status = statusObj.flatMap(InstrumentStatus.fromWireJSON)
        return (instance, status)
    }
}

private nonisolated(unsafe) let armingTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func encodeArmingState(_ state: ProcessSession.ArmingState) -> [String: Any] {
    switch state {
    case .unarmed:
        return ["state": "unarmed"]
    case .armed(let pattern, let armedAt):
        return [
            "state": "armed",
            "match_pattern": pattern,
            "armed_at": armingTimestampFormatter.string(from: armedAt),
        ]
    }
}

func decodeArmingState(_ obj: [String: Any]) -> ProcessSession.ArmingState? {
    guard let state = obj["state"] as? String else { return nil }
    switch state {
    case "unarmed":
        return .unarmed
    case "armed":
        guard let pattern = obj["match_pattern"] as? String,
            let armedAtStr = obj["armed_at"] as? String,
            let armedAt = armingTimestampFormatter.date(from: armedAtStr)
        else { return nil }
        return .armed(matchPattern: pattern, armedAt: armedAt)
    default:
        return nil
    }
}
