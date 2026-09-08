import Foundation

public struct SourceSyntaxStyle: Hashable, Sendable {
    public let color: RGBColor
    public let bold: Bool
    public let italic: Bool
}

public enum SourceSyntaxPalette {
    public static func style(for kind: TypeScriptToken.Kind, dark: Bool) -> SourceSyntaxStyle? {
        switch kind {
        case .keyword:
            return SourceSyntaxStyle(color: pick(dark, 0xFF7B72, 0xCF222E), bold: false, italic: false)
        case .string, .template:
            return SourceSyntaxStyle(color: pick(dark, 0xA5D6FF, 0x0A3069), bold: false, italic: false)
        case .number:
            return SourceSyntaxStyle(color: pick(dark, 0x79C0FF, 0x0550AE), bold: false, italic: false)
        case .regex:
            return SourceSyntaxStyle(color: pick(dark, 0xA5D6FF, 0x0A3069), bold: false, italic: false)
        case .comment:
            return SourceSyntaxStyle(color: pick(dark, 0x8B949E, 0x6E7781), bold: false, italic: false)
        case .identifier, .punctuation:
            return nil
        }
    }

    public static func semanticStyle(for type: String, modifiers: [String], dark: Bool) -> SourceSyntaxStyle? {
        let callable = SourceSyntaxStyle(color: pick(dark, 0xD2A8FF, 0x8250DF), bold: false, italic: false)
        switch type {
        case "function":
            return callable
        case "method", "member":
            return modifiers.contains("declaration") ? nil : callable
        case "parameter":
            return SourceSyntaxStyle(color: pick(dark, 0x79C0FF, 0x0550AE), bold: false, italic: false)
        case "class", "interface", "enum", "type", "typeParameter", "namespace":
            return SourceSyntaxStyle(color: pick(dark, 0xFFA657, 0x953800), bold: false, italic: false)
        default:
            return nil
        }
    }

    public static func fadedSemanticStyle(for type: String, modifiers: [String], dark: Bool) -> SourceSyntaxStyle {
        let base = semanticStyle(for: type, modifiers: modifiers, dark: dark)?.color ?? pick(dark, 0xE6EDF3, 0x1F2328)
        return SourceSyntaxStyle(color: blend(base, pick(dark, 0x0D1117, 0xFFFFFF), 0.55), bold: false, italic: false)
    }

    private static func pick(_ dark: Bool, _ onDark: UInt32, _ onLight: UInt32) -> RGBColor {
        let hex = dark ? onDark : onLight
        return RGBColor(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF))
    }

    private static func blend(_ color: RGBColor, _ background: RGBColor, _ backgroundWeight: Double) -> RGBColor {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) * (1 - backgroundWeight) + Double(b) * backgroundWeight).rounded())
        }
        return RGBColor(r: mix(color.r, background.r), g: mix(color.g, background.g), b: mix(color.b, background.b))
    }
}
