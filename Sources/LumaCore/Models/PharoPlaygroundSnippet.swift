import Foundation

/// A piece of Smalltalk on the playground page. The notebook is where work is
/// kept; these are the scratch ones, held with the project so a page survives
/// closing it.
public struct PharoPlaygroundSnippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var source: String
    /// What the last run produced, captured so the result survives closing the
    /// project, when the live object it came from is long gone.
    public var snapshot: PharoSnapshot?

    public init(id: UUID = UUID(), source: String, snapshot: PharoSnapshot? = nil) {
        self.id = id
        self.source = source
        self.snapshot = snapshot
    }
}
