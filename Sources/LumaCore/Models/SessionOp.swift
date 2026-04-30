import Foundation

/// A single pending mutation against a lab's sessions. Mirrors the
/// NotebookOp pattern: clients persist ops to the outbox as they happen,
/// the server deduplicates by `opID`, applies, and broadcasts the
/// authoritative result back. Session IDs are client-generated so a host
/// can attach offline and have the session announced on reconnect.
public enum SessionOp: Sendable {
    case add(Add)
    case updatePhase(UpdatePhase)
    case updateModules(UpdateModules)
    case claimHost(ClaimHost)
    case claimDriver(ClaimDriver)
    case addReplCell(AddReplCell)
    case addInstrument(AddInstrument)
    case updateInstrument(UpdateInstrument)
    case removeInstrument(RemoveInstrument)
    case addInsight(AddInsight)
    case removeInsight(RemoveInsight)
    case addCapture(AddCapture)
    case removeCapture(RemoveCapture)
    case remove(Remove)

    public var opID: UUID {
        switch self {
        case .add(let a): return a.opID
        case .updatePhase(let u): return u.opID
        case .updateModules(let u): return u.opID
        case .claimHost(let c): return c.opID
        case .claimDriver(let c): return c.opID
        case .addReplCell(let a): return a.opID
        case .addInstrument(let a): return a.opID
        case .updateInstrument(let u): return u.opID
        case .removeInstrument(let r): return r.opID
        case .addInsight(let a): return a.opID
        case .removeInsight(let r): return r.opID
        case .addCapture(let a): return a.opID
        case .removeCapture(let r): return r.opID
        case .remove(let r): return r.opID
        }
    }

    public var sessionID: UUID {
        switch self {
        case .add(let a): return a.sessionID
        case .updatePhase(let u): return u.sessionID
        case .updateModules(let u): return u.sessionID
        case .claimHost(let c): return c.sessionID
        case .claimDriver(let c): return c.sessionID
        case .addReplCell(let a): return a.sessionID
        case .addInstrument(let a): return a.sessionID
        case .updateInstrument(let u): return u.sessionID
        case .removeInstrument(let r): return r.sessionID
        case .addInsight(let a): return a.sessionID
        case .removeInsight(let r): return r.sessionID
        case .addCapture(let a): return a.sessionID
        case .removeCapture(let r): return r.sessionID
        case .remove(let r): return r.sessionID
        }
    }

    public var kind: String {
        switch self {
        case .add: return "add"
        case .updatePhase: return "update-phase"
        case .updateModules: return "update-modules"
        case .claimHost: return "claim-host"
        case .claimDriver: return "claim-driver"
        case .addReplCell: return "add-repl-cell"
        case .addInstrument: return "add-instrument"
        case .updateInstrument: return "update-instrument"
        case .removeInstrument: return "remove-instrument"
        case .addInsight: return "add-insight"
        case .removeInsight: return "remove-insight"
        case .addCapture: return "add-capture"
        case .removeCapture: return "remove-capture"
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

    public struct UpdateModules: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let modules: [ProcessModule]

        public init(
            opID: UUID = UUID(),
            sessionID: UUID,
            modules: [ProcessModule]
        ) {
            self.opID = opID
            self.sessionID = sessionID
            self.modules = modules
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

        public init(opID: UUID = UUID(), sessionID: UUID, instance: InstrumentInstance) {
            self.opID = opID
            self.sessionID = sessionID
            self.instance = instance
        }
    }

    public struct UpdateInstrument: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let instance: InstrumentInstance

        public init(opID: UUID = UUID(), sessionID: UUID, instance: InstrumentInstance) {
            self.opID = opID
            self.sessionID = sessionID
            self.instance = instance
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

    public struct AddCapture: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let capture: ITraceCaptureRecord

        public init(opID: UUID = UUID(), sessionID: UUID, capture: ITraceCaptureRecord) {
            self.opID = opID
            self.sessionID = sessionID
            self.capture = capture
        }
    }

    public struct RemoveCapture: Sendable {
        public let opID: UUID
        public let sessionID: UUID
        public let captureID: UUID

        public init(opID: UUID = UUID(), sessionID: UUID, captureID: UUID) {
            self.opID = opID
            self.sessionID = sessionID
            self.captureID = captureID
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
        case .updateModules(let u):
            obj["modules"] = u.modules.map { $0.toJSON() }
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
            if let instObj = a.instance.toWireJSON() {
                obj["instance"] = instObj
            }
        case .updateInstrument(let u):
            if let instObj = u.instance.toWireJSON() {
                obj["instance"] = instObj
            }
        case .removeInstrument(let r):
            obj["instance_id"] = r.instanceID.uuidString
        case .addInsight(let a):
            if let insightObj = a.insight.toWireJSON() {
                obj["insight"] = insightObj
            }
        case .removeInsight(let r):
            obj["insight_id"] = r.insightID.uuidString
        case .addCapture(let a):
            if let captureObj = a.capture.toWireJSON() {
                obj["capture"] = captureObj
            }
        case .removeCapture(let r):
            obj["capture_id"] = r.captureID.uuidString
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

        case "update-modules":
            guard let moduleObjs = obj["modules"] as? [[String: Any]] else { return nil }
            let modules = moduleObjs.compactMap(ProcessModule.fromJSON)
            return .updateModules(UpdateModules(
                opID: opID,
                sessionID: sessionID,
                modules: modules
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
                let inst = InstrumentInstance.fromWireJSON(instObj)
            else { return nil }
            return .addInstrument(AddInstrument(
                opID: opID,
                sessionID: sessionID,
                instance: inst
            ))

        case "update-instrument":
            guard let instObj = obj["instance"] as? [String: Any],
                let inst = InstrumentInstance.fromWireJSON(instObj)
            else { return nil }
            return .updateInstrument(UpdateInstrument(
                opID: opID,
                sessionID: sessionID,
                instance: inst
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

        case "remove-insight":
            guard let insightIDStr = obj["insight_id"] as? String,
                let insightID = UUID(uuidString: insightIDStr)
            else { return nil }
            return .removeInsight(RemoveInsight(
                opID: opID,
                sessionID: sessionID,
                insightID: insightID
            ))

        case "add-capture":
            guard let captureObj = obj["capture"] as? [String: Any],
                let capture = ITraceCaptureRecord.fromWireJSON(captureObj)
            else { return nil }
            return .addCapture(AddCapture(
                opID: opID,
                sessionID: sessionID,
                capture: capture
            ))

        case "remove-capture":
            guard let captureIDStr = obj["capture_id"] as? String,
                let captureID = UUID(uuidString: captureIDStr)
            else { return nil }
            return .removeCapture(RemoveCapture(
                opID: opID,
                sessionID: sessionID,
                captureID: captureID
            ))

        case "remove":
            return .remove(Remove(opID: opID, sessionID: sessionID))

        default:
            return nil
        }
    }
}
