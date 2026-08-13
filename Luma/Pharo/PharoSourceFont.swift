import SwiftUI

/// The monospaced face every Pharo editor sets source in, and the metrics the
/// marks and the columns line themselves up by.
enum PharoSourceFont {
    static let regular = PlatformFont.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular)

    static let bold = PlatformFont.monospacedSystemFont(ofSize: regular.pointSize, weight: .bold)

    static let characterWidth = ("0" as NSString).size(withAttributes: [.font: regular]).width
}

extension PlatformColor {
    /// An RRGGBB run colour from the image, read in the sRGB space it named it in.
    convenience init(pharoHex hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        #if canImport(AppKit)
            self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
            self.init(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    /// A run colour that resolves its own light or dark shade as the appearance
    /// changes, so a theme flip never has to rewrite the text's attributes.
    static func pharoRun(lightHex: String?, darkHex: String?) -> PlatformColor? {
        guard let lightHex, let darkHex else { return nil }
        #if canImport(AppKit)
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(pharoHex: isDark ? darkHex : lightHex)
            }
        #else
            return UIColor { trait in
                UIColor(pharoHex: trait.userInterfaceStyle == .dark ? darkHex : lightHex)
            }
        #endif
    }
}
