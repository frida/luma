import Foundation

public enum AddressNoteChange: Sendable {
    case noteAdded(AddressNote)
    case noteUpdated(AddressNote)
    case noteRemoved(noteID: UUID, sessionID: UUID)
    case messageAppended(AddressNoteMessage)
    case messageEdited(AddressNoteMessage)
}
