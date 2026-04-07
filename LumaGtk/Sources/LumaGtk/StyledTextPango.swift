import Foundation
import LumaCore

enum StyledTextPango {
    static func markup(for styled: StyledText) -> String {
        var out = ""
        for span in styled.spans {
            let escaped = escape(span.text)
            if span.foreground == nil && !span.isBold {
                out += escaped
                continue
            }
            var attrs = ""
            if let fg = span.foreground {
                attrs += String(format: " foreground=\"#%02x%02x%02x\"", fg.r, fg.g, fg.b)
            }
            if span.isBold {
                attrs += " weight=\"bold\""
            }
            out += "<span\(attrs)>\(escaped)</span>"
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
