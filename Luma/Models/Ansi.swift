//
//  Ansi.swift
//  R2Touch
//
//  Created by Francesco Tamagni on 26/01/24.
//

import Foundation
import SwiftUI

enum AnsiError: Error {
    case invalidEscapeSequence
    case invalidEscapeCode
    case unsupportedEscapeCode
    case invalidEscapeColorMode
    case unsupportedEscapeColorMode
    case invalidEscapeColor
    case internalError(reason: String)
}

private enum State {
    case printable
    case escape
    case code
    case end
}

private enum AnsiAttribute {
    case backgroundColor
    case foregroundColor
    case reset
}

private struct AnsiColor {
    var red = "0"
    var green = "0"
    var blue = "0"

    var uiColor: Color {
        Color(
            red: Double(self.red)! / 255.0,
            green: Double(self.green)! / 255.0,
            blue: Double(self.blue)! / 255.0)
    }

    var invertedUIColor: Color {
        Color(
            red: 1.0 - Double(self.red)! / 255.0,
            green: 1.0 - Double(self.green)! / 255.0,
            blue: 1.0 - Double(self.blue)! / 255.0)
    }

    var luminance: Double {
        0.2126 * Double(self.red)! / 255.0 + 0.7152 * Double(self.green)! / 255.0 + 0.0722 * Double(self.blue)! / 255.0
    }
}

private let CHR_ESCAPE: Character = "\u{001B}"
private let CHR_BRACKET: Character = "["
private let CHR_SEMI: Character = ";"
private let CHR_M: Character = "m"

func parseAnsi(_ input: String) throws -> AttributedString {
    var result = AttributedString()

    var startIndex = result.startIndex
    var endIndex = result.endIndex

    var fgColor: AnsiColor?
    var bgColor: AnsiColor?
    var fgUIColor: Color?
    var bgUIColor: Color?
    var isBold = false
    var isReverseVideo = false

    var state: State = .printable

    var paramBuffer = ""
    var params: [String] = []

    func flushStyleRun() {
        guard startIndex < endIndex else { return }

        let effectiveFG = isReverseVideo ? bgUIColor : fgUIColor
        let effectiveBG = isReverseVideo ? fgUIColor : bgUIColor

        if let bg = effectiveBG {
            result[startIndex..<endIndex].backgroundColor = bg
        }
        if let fg = effectiveFG {
            result[startIndex..<endIndex].foregroundColor = fg
        }

        if isBold {
            result[startIndex..<endIndex].font = .system(.body, design: .monospaced).bold()
        } else {
            result[startIndex..<endIndex].font = .system(.body, design: .monospaced)
        }

        startIndex = endIndex
    }

    func recomputeContrastIfNeeded() {
        guard let f = fgColor, let b = bgColor else { return }
        let luminanceDiff = abs(f.luminance - b.luminance)
        if luminanceDiff < 0.1, b.luminance > 0.5 {
            bgUIColor = b.invertedUIColor
        }
    }

    func applySGR(_ rawParams: [String]) throws {
        let normalized: [String] = rawParams.isEmpty ? ["0"] : rawParams.map { $0.isEmpty ? "0" : $0 }

        var i = 0
        while i < normalized.count {
            let p = normalized[i]

            switch p {
            case "0":
                fgColor = nil
                bgColor = nil
                fgUIColor = nil
                bgUIColor = nil
                isBold = false
                isReverseVideo = false
            case "1":
                isBold = true
            case "22":
                isBold = false
            case "7":
                isReverseVideo = true
            case "27":
                isReverseVideo = false

            case "38", "48":
                let isForeground = (p == "38")
                guard i + 1 < normalized.count else { throw AnsiError.invalidEscapeColorMode }
                let mode = normalized[i + 1]
                guard mode == "2" else { throw AnsiError.unsupportedEscapeColorMode }

                guard i + 4 < normalized.count else { throw AnsiError.invalidEscapeColor }
                let r = normalized[i + 2]
                let g = normalized[i + 3]
                let b = normalized[i + 4]

                func validateByte(_ s: String) throws -> String {
                    guard let v = Int(s), (0...255).contains(v) else { throw AnsiError.invalidEscapeColor }
                    return String(v)
                }

                var c = AnsiColor()
                c.red = try validateByte(r)
                c.green = try validateByte(g)
                c.blue = try validateByte(b)

                if isForeground {
                    fgColor = c
                    fgUIColor = c.uiColor
                } else {
                    bgColor = c
                    bgUIColor = c.uiColor
                }

                recomputeContrastIfNeeded()
                i += 4
            case "39":
                fgColor = nil
                fgUIColor = nil
            case "49":
                bgColor = nil
                bgUIColor = nil

            default:
                throw AnsiError.unsupportedEscapeCode
            }

            i += 1
        }
    }

    try input.forEach { char in
        switch state {
        case .printable:
            if char == CHR_ESCAPE {
                state = .escape
            } else {
                result.append(AttributedString(String(char)))
                endIndex = result.endIndex
            }

        case .escape:
            guard char == CHR_BRACKET else { throw AnsiError.invalidEscapeSequence }
            params.removeAll(keepingCapacity: true)
            paramBuffer.removeAll(keepingCapacity: true)
            state = .code

        case .code:
            if char.isNumber {
                paramBuffer.append(char)
            } else if char == CHR_SEMI {
                params.append(paramBuffer)
                paramBuffer.removeAll(keepingCapacity: true)
            } else if char == CHR_M {
                params.append(paramBuffer)
                paramBuffer.removeAll(keepingCapacity: true)

                flushStyleRun()
                try applySGR(params)

                state = .printable
            } else {
                throw AnsiError.invalidEscapeCode
            }

        case .end:
            throw AnsiError.internalError(reason: "Unexpected parser state: \(state)")
        }
    }

    endIndex = result.endIndex
    flushStyleRun()

    return result
}

func stripAnsi(_ input: String) -> String {
    var result = ""

    var state: State = .printable

    input.forEach { char in
        switch state {
        case .escape:
            if char == CHR_BRACKET {
                state = .code
            } else {
                state = .printable
            }
        case .code:
            if char == CHR_M {
                state = .end
            }
        case .end:
            state = .printable
            fallthrough
        case .printable:
            if char == CHR_ESCAPE {
                state = .escape
            } else {
                result.append(char)
            }
        }
    }

    return result
}
