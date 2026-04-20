import LumaCore
import SwiftUI

#if canImport(AppKit)
import AppKit

extension StyledText {
    func nsAttributed(font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in spans {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: span.isBold
                    ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
                    : font
            ]
            if let fg = span.foreground {
                attrs[.foregroundColor] = NSColor(
                    calibratedRed: CGFloat(fg.r) / 255,
                    green: CGFloat(fg.g) / 255,
                    blue: CGFloat(fg.b) / 255,
                    alpha: 1
                )
            } else {
                attrs[.foregroundColor] = NSColor(calibratedWhite: 0.7, alpha: 1)
            }
            result.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        return result
    }
}
#endif

extension StyledText {
    var attributed: AttributedString {
        var result = AttributedString()
        for span in spans {
            var part = AttributedString(span.text)
            if let fg = span.foreground {
                part.foregroundColor = Color(red: Double(fg.r) / 255, green: Double(fg.g) / 255, blue: Double(fg.b) / 255)
            }
            if let bg = span.background {
                part.backgroundColor = Color(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255)
            }
            if span.isBold {
                part.font = .system(.footnote, design: .monospaced).bold()
            }
            result.append(part)
        }
        return result
    }
}
