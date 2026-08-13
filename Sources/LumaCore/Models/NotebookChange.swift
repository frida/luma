import Foundation

/// Which of an entry's fields a change touched, so a view can apply just what
/// moved rather than diffing the whole entry or rebuilding its row.
public struct NotebookEntryFields: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let title = NotebookEntryFields(rawValue: 1 << 0)
    public static let details = NotebookEntryFields(rawValue: 1 << 1)
    public static let processName = NotebookEntryFields(rawValue: 1 << 2)
    public static let pharoSnapshot = NotebookEntryFields(rawValue: 1 << 3)

    public static let all: NotebookEntryFields = [.title, .details, .processName, .pharoSnapshot]
}

public enum NotebookChange: Sendable {
    /// A single entry appeared — locally via `addNotebookEntry` or
    /// received live via collaboration. Use `entry.editors.first` to tell
    /// who created it.
    case added(NotebookEntry)
    /// A bulk load of existing entries, typically on join, that should
    /// repopulate UI without triggering "new entry" side effects like
    /// desktop notifications.
    case snapshot([NotebookEntry])
    /// An entry changed; `changed` names the fields that moved so a view can
    /// update those in place instead of rebuilding the whole row.
    case updated(NotebookEntry, changed: NotebookEntryFields)
    case removed(UUID)
    case reordered
}
