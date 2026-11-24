import Foundation

public struct LabSubject: Hashable, Sendable {
    public enum Family: String, Sendable {
        case entry
        case definition
        case pattern
        case mission
        case addressNote
        case objectChat
        case objectChatMessage
        case session
        case replCell
        case instrument
        case insight
        case trace
    }

    public let family: Family
    public let id: UUID

    public init(_ family: Family, _ id: UUID) {
        self.family = family
        self.id = id
    }
}

extension QueuedOp {
    var labSubject: LabSubject {
        switch self {
        case .notebook(let op): LabSubject(.entry, op.entryID)
        case .session(let op): op.labSubject
        case .customInstrument(let op): LabSubject(.definition, op.defID)
        case .pattern(let op): LabSubject(.pattern, op.sourceID)
        case .mission(let op): LabSubject(.mission, op.missionID)
        case .addressNote(let op): LabSubject(.addressNote, op.noteID)
        case .objectChat(let op): op.labSubject
        }
    }
}

extension ObjectChatOp {
    var labSubject: LabSubject {
        switch change {
        case .messageAppend(let message): LabSubject(.objectChatMessage, message.id)
        case .messageEdit(_, let messageID, _), .messageRemove(_, let messageID): LabSubject(.objectChatMessage, messageID)
        default: LabSubject(.objectChat, chatID)
        }
    }
}

extension SessionOp {
    var labSubject: LabSubject {
        switch self {
        case .addReplCell(let a): LabSubject(.replCell, a.cell.id)
        case .updateReplCell(let u): LabSubject(.replCell, u.cell.id)
        case .addInstrument(let a): LabSubject(.instrument, a.instance.id)
        case .updateInstrument(let u): LabSubject(.instrument, u.instance.id)
        case .removeInstrument(let r): LabSubject(.instrument, r.instanceID)
        case .addInsight(let a): LabSubject(.insight, a.insight.id)
        case .updateInsight(let u): LabSubject(.insight, u.insight.id)
        case .removeInsight(let r): LabSubject(.insight, r.insightID)
        case .upsertTrace(let u): LabSubject(.trace, u.trace.id)
        case .removeTrace(let r): LabSubject(.trace, r.traceID)
        case .setPlacements(let s): s.subject.labSubject
        default: LabSubject(.session, sessionID)
        }
    }
}

extension SessionOp.SetPlacements.Subject {
    var labSubject: LabSubject {
        switch self {
        case .replCell(let id): LabSubject(.replCell, id)
        case .insight(let id): LabSubject(.insight, id)
        case .widget(let instanceID, _): LabSubject(.instrument, instanceID)
        }
    }
}

extension CollaborationSession.Session {
    var labSubjects: [LabSubject] {
        [LabSubject(.session, id)]
            + replCells.map { LabSubject(.replCell, $0.id) }
            + instruments.map { LabSubject(.instrument, $0.id) }
            + insights.map { LabSubject(.insight, $0.id) }
            + traces.map { LabSubject(.trace, $0.id) }
    }
}
