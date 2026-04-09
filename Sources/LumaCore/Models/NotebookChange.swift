import Foundation

public enum NotebookChange: Sendable {
    case added(NotebookEntry)
    case updated(NotebookEntry)
    case removed(UUID)
    case reordered
}
