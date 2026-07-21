import Foundation

/// A piece of Smalltalk on the playground page. The notebook is where work is
/// kept; these are the scratch ones, held with the project so a page survives
/// closing it.
public struct PharoPlaygroundSnippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var source: String

    public init(id: UUID = UUID(), source: String) {
        self.id = id
        self.source = source
    }
}
