import Foundation

public enum DisplayTruncation {
    /// Maximum text size, in bytes, that the UI renders inline for a single
    /// REPL/console entry. Strings longer than this are head-truncated with a
    /// marker indicating the original size. Layout engines bog down on very
    /// large attributed strings, and the user can't usefully scan 5 MiB of
    /// inline text anyway.
    public static let maxInlineBytes = 2 * 1024
    public static let maxKeptBytes = 64 * 1024

    public static func truncated(_ text: String, limit: Int = maxInlineBytes) -> String {
        let byteCount = text.utf8.count
        if byteCount <= limit { return text }
        let head = String(decoding: text.utf8.prefix(limit), as: UTF8.self)
        return head + "\n… <truncated; \(byteCount) bytes total>"
    }

    public static func truncated(_ styled: StyledText, limit: Int = maxInlineBytes) -> StyledText {
        let plain = styled.plainText
        let byteCount = plain.utf8.count
        if byteCount <= limit { return styled }

        var charCount = 0
        var bytes = 0
        for character in plain {
            let characterBytes = String(character).utf8.count
            if bytes + characterBytes > limit { break }
            bytes += characterBytes
            charCount += 1
        }

        let head = styled.slice(charRange: 0..<charCount)
        let marker = StyledText.Span(text: "\n… <truncated; \(byteCount) bytes total>")
        return StyledText(spans: head.spans + [marker])
    }
}
