import Foundation

public enum StoredValue: Hashable, Sendable {
    case replCell(UUID)
    case notebookEntry(UUID)
    case event(UUID)
}
