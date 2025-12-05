import Foundation
import SwiftData

enum InstrumentKind: String, Codable {
    case tracer
    case hookPack
    case codeShare
}

@Model
final class InstrumentInstance {
    @Attribute(.unique) var id: UUID
    var kind: InstrumentKind

    var sourceIdentifier: String

    var isEnabled: Bool

    var configJSON: Data

    @Relationship(inverse: \ProcessSession.instruments)
    var session: ProcessSession?

    @MainActor
    var displayName: String {
        InstrumentMetadataRegistry.shared.displayName(for: self)
    }

    @MainActor
    var displayIcon: InstrumentIcon {
        InstrumentMetadataRegistry.shared.icon(for: self)
    }

    init(
        kind: InstrumentKind,
        sourceIdentifier: String,
        isEnabled: Bool = true,
        configJSON: Data,
        session: ProcessSession? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.sourceIdentifier = sourceIdentifier
        self.isEnabled = isEnabled
        self.configJSON = configJSON
        self.session = session
    }
}
