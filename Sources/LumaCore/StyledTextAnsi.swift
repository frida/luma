import Foundation

extension StyledText {
    public static func parseAnsi(_ input: String) -> StyledText {
        var spans: [Span] = []
        var current = ""
        var fg: RGBColor?
        var bg: RGBColor?
        var bold = false
        var reverseVideo = false

        func flush() {
            guard !current.isEmpty else { return }
            let f = reverseVideo ? bg : fg
            let b = reverseVideo ? fg : bg
            spans.append(Span(text: current, foreground: f, background: b, isBold: bold))
            current = ""
        }

        var state: State = .printable
        var paramBuffer = ""
        var params: [String] = []

        for char in input {
            switch state {
            case .printable:
                if char == "\u{001B}" {
                    flush()
                    state = .escape
                } else {
                    current.append(char)
                }
            case .escape:
                if char == "[" {
                    params.removeAll(keepingCapacity: true)
                    paramBuffer.removeAll(keepingCapacity: true)
                    state = .code
                } else {
                    state = .printable
                }
            case .code:
                if char.isNumber {
                    paramBuffer.append(char)
                } else if char == ";" {
                    params.append(paramBuffer)
                    paramBuffer.removeAll(keepingCapacity: true)
                } else if char == "m" {
                    params.append(paramBuffer)
                    paramBuffer.removeAll(keepingCapacity: true)
                    applySGR(params, fg: &fg, bg: &bg, bold: &bold, reverseVideo: &reverseVideo)
                    state = .printable
                } else {
                    state = .printable
                }
            }
        }

        flush()
        return StyledText(spans: spans)
    }

    public func slice(charRange: Range<Int>) -> StyledText {
        var out: [Span] = []
        var cursor = 0
        let lower = charRange.lowerBound
        let upper = charRange.upperBound

        for span in spans {
            let spanLen = span.text.count
            let spanEnd = cursor + spanLen

            if spanEnd <= lower || cursor >= upper {
                cursor = spanEnd
                continue
            }

            let localStart = max(0, lower - cursor)
            let localEnd = min(spanLen, upper - cursor)
            if localStart < localEnd {
                let s = span.text.index(span.text.startIndex, offsetBy: localStart)
                let e = span.text.index(span.text.startIndex, offsetBy: localEnd)
                out.append(Span(
                    text: String(span.text[s..<e]),
                    foreground: span.foreground,
                    background: span.background,
                    isBold: span.isBold
                ))
            }

            cursor = spanEnd
            if cursor >= upper { break }
        }

        return StyledText(spans: out)
    }
}

private enum State {
    case printable
    case escape
    case code
}

private func applySGR(
    _ params: [String],
    fg: inout RGBColor?,
    bg: inout RGBColor?,
    bold: inout Bool,
    reverseVideo: inout Bool
) {
    let normalized: [String] = params.isEmpty ? ["0"] : params.map { $0.isEmpty ? "0" : $0 }
    var i = 0
    while i < normalized.count {
        let p = normalized[i]
        switch p {
        case "0":
            fg = nil
            bg = nil
            bold = false
            reverseVideo = false
        case "1":
            bold = true
        case "22":
            bold = false
        case "7":
            reverseVideo = true
        case "27":
            reverseVideo = false
        case "38", "48":
            let isForeground = (p == "38")
            guard i + 4 < normalized.count, normalized[i + 1] == "2" else { break }
            let r = UInt8(normalized[i + 2]) ?? 0
            let g = UInt8(normalized[i + 3]) ?? 0
            let b = UInt8(normalized[i + 4]) ?? 0
            let color = RGBColor(r: r, g: g, b: b)
            if isForeground { fg = color } else { bg = color }
            i += 4
        case "39":
            fg = nil
        case "49":
            bg = nil
        default:
            break
        }
        i += 1
    }
}
