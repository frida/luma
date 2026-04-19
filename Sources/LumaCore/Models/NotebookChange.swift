import Foundation

public enum NotebookChange: Sendable {
    /// A single entry appeared — locally via `addNotebookEntry` or
    /// received live via collaboration. Use `entry.author` to tell who
    /// produced it.
    case added(NotebookEntry)
    /// A bulk load of existing entries, typically on join, that should
    /// repopulate UI without triggering "new entry" side effects like
    /// desktop notifications.
    case snapshot([NotebookEntry])
    case updated(NotebookEntry)
    case removed(UUID)
    case reordered
}
