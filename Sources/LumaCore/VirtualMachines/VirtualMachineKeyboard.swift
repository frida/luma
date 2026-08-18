import Foundation

public enum VirtualMachineKeyboard {
    public static func code(for character: Character) -> UInt32? {
        codesByCharacter[Character(character.lowercased())]
    }

    public static func code(for key: VirtualMachineKey) -> UInt32 {
        switch key {
        case .escape: return 0x01
        case .backspace: return 0x0e
        case .tab: return 0x0f
        case .return: return 0x1c
        case .space: return 0x39
        case .leftShift: return 0x2a
        case .leftControl: return 0x1d
        case .leftAlt: return 0x38
        case .capsLock: return 0x3a
        case .upArrow: return extended | 0x48
        case .downArrow: return extended | 0x50
        case .leftArrow: return extended | 0x4b
        case .rightArrow: return extended | 0x4d
        case .delete: return extended | 0x53
        case .home: return extended | 0x47
        case .end: return extended | 0x4f
        case .pageUp: return extended | 0x49
        case .pageDown: return extended | 0x51
        case .function(let number): return functionKeyCodes[Int(number) - 1]
        }
    }

    private static let extended: UInt32 = 0x80

    private static let functionKeyCodes: [UInt32] = [
        0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58,
    ]

    private static let codesByCharacter: [Character: UInt32] = {
        let rows: [(String, [UInt32])] = [
            ("1234567890-=", Array(0x02...0x0d)),
            ("qwertyuiop[]", Array(0x10...0x1b)),
            ("asdfghjkl;'`", Array(0x1e...0x29)),
            ("\\zxcvbnm,./", Array(0x2b...0x35)),
            (" ", [0x39]),
        ]
        var codes: [Character: UInt32] = [:]
        for (characters, scancodes) in rows {
            for (character, scancode) in zip(characters, scancodes) {
                codes[character] = scancode
            }
        }
        return codes
    }()
}

public enum VirtualMachineKey: Sendable, Equatable {
    case escape
    case backspace
    case tab
    case `return`
    case space
    case leftShift
    case leftControl
    case leftAlt
    case capsLock
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case delete
    case home
    case end
    case pageUp
    case pageDown
    case function(UInt8)
}
