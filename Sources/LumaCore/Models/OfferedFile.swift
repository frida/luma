import Foundation

public struct OfferedFile: Identifiable, Sendable, Equatable {
    public static let maxBytes = 64 * 1024 * 1024
    public static let maxChunkBytes = 4 * 1024 * 1024
    public static let maxNameBytes = 255
    public static let maxMediaTypeLength = 255
    public static let maxOpen = 4

    public let id: UUID
    public let name: String
    public let mediaType: String
    public let instrumentName: String

    static func problem(name: String, mediaType: String) -> String? {
        if let nameProblem = Self.nameProblem(name) {
            return "\"\(name)\" is not a plain file name: \(nameProblem)"
        }
        guard mediaType.count <= maxMediaTypeLength, mediaType.wholeMatch(of: mediaTypePattern) != nil else {
            return "\"\(mediaType)\" is not a media type such as \"model/obj\""
        }
        return nil
    }

    private static var mediaTypePattern: Regex<Substring> { /[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]{0,126}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]{0,126}/ }

    private static func nameProblem(_ name: String) -> String? {
        if name.isEmpty {
            return "it is empty"
        }
        if name.utf8.count > maxNameBytes {
            return "it is longer than \(maxNameBytes) bytes as UTF-8"
        }
        if let reserved = name.first(where: { "/\\<>:\"|?*".contains($0) }) {
            return "it contains \"\(reserved)\""
        }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "it contains a control character"
        }
        if name.hasPrefix(".") {
            return "it starts with a dot"
        }
        if name.hasSuffix(".") {
            return "it ends with a dot"
        }
        return name.hasSuffix(" ") ? "it ends with a space" : nil
    }
}

public struct OfferedFileSummary: Sendable, Equatable {
    public let name: String
    public let mediaType: String
    public let size: Int?
}
