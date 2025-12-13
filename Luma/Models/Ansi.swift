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
    case mode
    case red
    case green
    case blue
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
    var endIndex = result.endIndex
    var startIndex = result.startIndex
    var state: State = .printable
    var number = ""
    var ansiAttribute: AnsiAttribute?
    var color = AnsiColor()
    var fColor: AnsiColor?
    var bColor: AnsiColor?
    var bgUIColor: Color?
    var fgUIColor: Color?
    try input.forEach { char in
        switch state {
        case .escape:
            if char == CHR_BRACKET {
                state = .code
            } else {
                throw AnsiError.invalidEscapeSequence
            }
        case .code:
            if char.isNumber {
                number.append(char)
            } else if char == CHR_SEMI || char == CHR_M {
                switch number {
                case "38":
                    ansiAttribute = .foregroundColor
                case "48":
                    ansiAttribute = .backgroundColor
                case "0":
                    ansiAttribute = .reset
                case "7":
                    ansiAttribute = .none
                    break
                default:
                    throw AnsiError.unsupportedEscapeCode
                }

                number = ""

                if char == CHR_SEMI {
                    state = .mode
                } else {
                    state = .end
                }
            } else {
                throw AnsiError.invalidEscapeCode
            }
        case .mode:
            if char.isNumber {
                number.append(char)
            } else if char == CHR_SEMI {
                switch number {
                case "2":
                    state = .red
                default:
                    throw AnsiError.unsupportedEscapeColorMode
                }
                number = ""
            } else {
                throw AnsiError.invalidEscapeColorMode
            }
        case .red:
            if char.isNumber {
                number.append(char)
            } else if char == CHR_SEMI {
                color.red = number
                number = ""
                state = .green
            } else {
                throw AnsiError.invalidEscapeColor
            }
        case .green:
            if char.isNumber {
                number.append(char)
            } else if char == CHR_SEMI {
                color.green = number
                number = ""
                state = .blue
            } else {
                throw AnsiError.invalidEscapeColor
            }
        case .blue:
            if char.isNumber {
                number.append(char)
            } else if char == CHR_M {
                color.blue = number
                number = ""
                state = .end
            } else {
                throw AnsiError.invalidEscapeColor
            }
        case .end:
            state = .printable

            switch ansiAttribute {
            case .backgroundColor:
                if let color = bgUIColor {
                    result[startIndex..<endIndex].backgroundColor = color
                }
                if let color = fgUIColor {
                    result[startIndex..<endIndex].foregroundColor = color
                }
                startIndex = endIndex
                bgUIColor = color.uiColor
                bColor = color

                if let fColor = fColor, let bColor = bColor {
                    let luminanceDiff = abs(fColor.luminance - bColor.luminance)
                    if luminanceDiff < 0.1 {
                        if bColor.luminance > 0.5 {
                            bgUIColor = bColor.invertedUIColor
                        }
                    }
                }
            case .foregroundColor:
                if let color = bgUIColor {
                    result[startIndex..<endIndex].backgroundColor = color
                }
                if let color = fgUIColor {
                    result[startIndex..<endIndex].foregroundColor = color
                }
                startIndex = endIndex
                fgUIColor = color.uiColor
                fColor = color

                if let fColor = fColor, let bColor = bColor {
                    let luminanceDiff = abs(fColor.luminance - bColor.luminance)
                    if luminanceDiff < 0.1 {
                        if bColor.luminance > 0.5 {
                            bgUIColor = bColor.invertedUIColor
                        }
                    }
                }
            case .reset:
                if let color = bgUIColor {
                    result[startIndex..<endIndex].backgroundColor = color
                }
                if let color = fgUIColor {
                    result[startIndex..<endIndex].foregroundColor = color
                }
                startIndex = endIndex
                fgUIColor = nil
                bgUIColor = nil
                bColor = nil
                fColor = nil
                break
            case .none:
                break
            }

            fallthrough
        case .printable:
            if char == CHR_ESCAPE {
                state = .escape
            } else {
                result.append(AttributedString(String(char)))
            }
        }

        endIndex = result.endIndex
    }

    if let color = bgUIColor {
        result[startIndex..<endIndex].backgroundColor = color
    }
    if let color = fgUIColor {
        result[startIndex..<endIndex].foregroundColor = color
    }

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
        default:
            break
        }
    }

    return result
}
