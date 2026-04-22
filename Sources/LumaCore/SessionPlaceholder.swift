import Foundation

public enum SessionPlaceholder {
    public struct Palette: Sendable, Equatable {
        public let primaryHue: Double
        public let primarySaturation: Double
        public let primaryBrightness: Double
        public let secondaryHue: Double
        public let secondarySaturation: Double
        public let secondaryBrightness: Double
    }

    public static func initials(for displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2,
            let firstChar = words.first?.first,
            let secondChar = words.dropFirst().first?.first
        {
            return String([firstChar, secondChar]).uppercased()
        }
        if let firstChar = words.first?.first {
            return String(firstChar).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    public static func palette(for seed: String) -> Palette {
        let hash = fnv1a64(seed)
        let primary = Double(hash % 360) / 360.0
        let secondary = (primary + 0.08).truncatingRemainder(dividingBy: 1.0)
        return Palette(
            primaryHue: primary,
            primarySaturation: 0.55,
            primaryBrightness: 0.78,
            secondaryHue: secondary,
            secondarySaturation: 0.70,
            secondaryBrightness: 0.55
        )
    }

    /// FNV-1a 64-bit — keep it stable across runs and platforms so a
    /// given session renders the same colour everywhere. Swift's
    /// default `String.hashValue` is seeded per process.
    private static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
