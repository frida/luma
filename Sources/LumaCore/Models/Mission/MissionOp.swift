import Foundation

public enum MissionOp: Sendable {
    case missionUpsert(MissionUpsert)
    case missionRemove(MissionRemove)
    case turnAppend(TurnAppend)
    case actionUpsert(ActionUpsert)
    case findingUpsert(FindingUpsert)
    case findingRemove(FindingRemove)
    case evidenceAdd(EvidenceAdd)
    case steerAppend(SteerAppend)
    case steerConsume(SteerConsume)

    public var opID: UUID {
        switch self {
        case .missionUpsert(let u): return u.opID
        case .missionRemove(let r): return r.opID
        case .turnAppend(let a): return a.opID
        case .actionUpsert(let u): return u.opID
        case .findingUpsert(let u): return u.opID
        case .findingRemove(let r): return r.opID
        case .evidenceAdd(let a): return a.opID
        case .steerAppend(let a): return a.opID
        case .steerConsume(let c): return c.opID
        }
    }

    public var missionID: UUID {
        switch self {
        case .missionUpsert(let u): return u.mission.id
        case .missionRemove(let r): return r.missionID
        case .turnAppend(let a): return a.turn.missionID
        case .actionUpsert(let u): return u.action.missionID
        case .findingUpsert(let u): return u.finding.missionID
        case .findingRemove(let r): return r.missionID
        case .evidenceAdd(let a): return a.missionID
        case .steerAppend(let a): return a.steer.missionID
        case .steerConsume(let c): return c.missionID
        }
    }

    public var rowID: UUID? {
        switch self {
        case .missionUpsert, .missionRemove, .findingRemove, .steerConsume: return nil
        case .steerAppend(let a): return a.steer.id
        case .turnAppend(let a): return a.turn.id
        case .actionUpsert(let u): return u.action.id
        case .findingUpsert(let u): return u.finding.id
        case .evidenceAdd(let a): return a.evidence.id
        }
    }

    public var kind: String {
        switch self {
        case .missionUpsert: return "mission_upsert"
        case .missionRemove: return "mission_remove"
        case .turnAppend: return "turn_append"
        case .actionUpsert: return "action_upsert"
        case .findingUpsert: return "finding_upsert"
        case .findingRemove: return "finding_remove"
        case .evidenceAdd: return "evidence_add"
        case .steerAppend: return "steer_append"
        case .steerConsume: return "steer_consume"
        }
    }

    public struct MissionUpsert: Sendable {
        public let opID: UUID
        public var mission: Mission

        public init(opID: UUID = UUID(), mission: Mission) {
            self.opID = opID
            self.mission = mission
        }
    }

    public struct MissionRemove: Sendable {
        public let opID: UUID
        public let missionID: UUID

        public init(opID: UUID = UUID(), missionID: UUID) {
            self.opID = opID
            self.missionID = missionID
        }
    }

    public struct TurnAppend: Sendable {
        public let opID: UUID
        public let turn: MissionTurn

        public init(opID: UUID = UUID(), turn: MissionTurn) {
            self.opID = opID
            self.turn = turn
        }
    }

    public struct ActionUpsert: Sendable {
        public let opID: UUID
        public let action: MissionAction

        public init(opID: UUID = UUID(), action: MissionAction) {
            self.opID = opID
            self.action = action
        }
    }

    public struct FindingUpsert: Sendable {
        public let opID: UUID
        public let finding: MissionFinding

        public init(opID: UUID = UUID(), finding: MissionFinding) {
            self.opID = opID
            self.finding = finding
        }
    }

    public struct FindingRemove: Sendable {
        public let opID: UUID
        public let missionID: UUID
        public let findingID: UUID

        public init(opID: UUID = UUID(), missionID: UUID, findingID: UUID) {
            self.opID = opID
            self.missionID = missionID
            self.findingID = findingID
        }
    }

    public struct EvidenceAdd: Sendable {
        public let opID: UUID
        public let missionID: UUID
        public let evidence: MissionEvidence

        public init(opID: UUID = UUID(), missionID: UUID, evidence: MissionEvidence) {
            self.opID = opID
            self.missionID = missionID
            self.evidence = evidence
        }
    }

    public struct SteerAppend: Sendable {
        public let opID: UUID
        public let steer: MissionSteer

        public init(opID: UUID = UUID(), steer: MissionSteer) {
            self.opID = opID
            self.steer = steer
        }
    }

    public struct SteerConsume: Sendable {
        public let opID: UUID
        public let missionID: UUID
        public let steerIDs: [UUID]

        public init(opID: UUID = UUID(), missionID: UUID, steerIDs: [UUID]) {
            self.opID = opID
            self.missionID = missionID
            self.steerIDs = steerIDs
        }
    }

    public func toJSON() -> [String: Any] {
        var obj: [String: Any] = [
            "op_id": opID.uuidString,
            "kind": kind,
        ]
        switch self {
        case .missionUpsert(let u):
            obj["mission"] = encodeRow(u.mission)
        case .missionRemove(let r):
            obj["mission_id"] = r.missionID.uuidString
        case .turnAppend(let a):
            obj["turn"] = encodeRow(a.turn)
        case .actionUpsert(let u):
            obj["action"] = encodeRow(u.action)
        case .findingUpsert(let u):
            obj["finding"] = encodeRow(u.finding)
        case .findingRemove(let r):
            obj["mission_id"] = r.missionID.uuidString
            obj["finding_id"] = r.findingID.uuidString
        case .evidenceAdd(let a):
            obj["mission_id"] = a.missionID.uuidString
            obj["evidence"] = encodeRow(a.evidence)
        case .steerAppend(let a):
            obj["steer"] = encodeRow(a.steer)
        case .steerConsume(let c):
            obj["mission_id"] = c.missionID.uuidString
            obj["steer_ids"] = c.steerIDs.map(\.uuidString)
        }
        return obj
    }

    public static func fromJSON(_ obj: [String: Any]) -> MissionOp? {
        guard let opIDStr = obj["op_id"] as? String,
            let opID = UUID(uuidString: opIDStr),
            let kind = obj["kind"] as? String
        else { return nil }

        switch kind {
        case "mission_upsert":
            guard let row = obj["mission"] as? [String: Any],
                let m: Mission = decodeRow(row)
            else { return nil }
            return .missionUpsert(MissionUpsert(opID: opID, mission: m))
        case "mission_remove":
            guard let idStr = obj["mission_id"] as? String,
                let id = UUID(uuidString: idStr)
            else { return nil }
            return .missionRemove(MissionRemove(opID: opID, missionID: id))
        case "turn_append":
            guard let row = obj["turn"] as? [String: Any],
                let t: MissionTurn = decodeRow(row)
            else { return nil }
            return .turnAppend(TurnAppend(opID: opID, turn: t))
        case "action_upsert":
            guard let row = obj["action"] as? [String: Any],
                let a: MissionAction = decodeRow(row)
            else { return nil }
            return .actionUpsert(ActionUpsert(opID: opID, action: a))
        case "finding_upsert":
            guard let row = obj["finding"] as? [String: Any],
                let f: MissionFinding = decodeRow(row)
            else { return nil }
            return .findingUpsert(FindingUpsert(opID: opID, finding: f))
        case "finding_remove":
            guard let mIDStr = obj["mission_id"] as? String,
                let mID = UUID(uuidString: mIDStr),
                let fIDStr = obj["finding_id"] as? String,
                let fID = UUID(uuidString: fIDStr)
            else { return nil }
            return .findingRemove(FindingRemove(opID: opID, missionID: mID, findingID: fID))
        case "evidence_add":
            guard let mIDStr = obj["mission_id"] as? String,
                let mID = UUID(uuidString: mIDStr),
                let row = obj["evidence"] as? [String: Any],
                let e: MissionEvidence = decodeRow(row)
            else { return nil }
            return .evidenceAdd(EvidenceAdd(opID: opID, missionID: mID, evidence: e))
        case "steer_append":
            guard let row = obj["steer"] as? [String: Any],
                let steer: MissionSteer = decodeRow(row)
            else { return nil }
            return .steerAppend(SteerAppend(opID: opID, steer: steer))
        case "steer_consume":
            guard let mIDStr = obj["mission_id"] as? String,
                let mID = UUID(uuidString: mIDStr),
                let ids = obj["steer_ids"] as? [String]
            else { return nil }
            return .steerConsume(SteerConsume(opID: opID, missionID: mID, steerIDs: ids.compactMap(UUID.init(uuidString:))))
        default:
            return nil
        }
    }
}
