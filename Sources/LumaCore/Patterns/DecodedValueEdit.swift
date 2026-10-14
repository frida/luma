import Foundation

public struct DecodedValueEdit: Sendable {
    public let address: UInt64
    public let text: String
    private let container: [UInt8]
    private let layout: Layout

    private enum Layout {
        case number(Scalar, ByteOrder)
        case bits(Scalar, first: Int, count: Int, ByteOrder)
        case floating(ByteOrder)
        case characters(unit: Int, ByteOrder)
    }

    private enum Scalar {
        case signed
        case unsigned
        case boolean
    }

    private enum ByteOrder: CaseIterable {
        case little
        case big
    }

    public enum Problem: LocalizedError {
        case unparsable(expected: String)
        case outOfRange(lowest: String, highest: String)
        case tooLong(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .unparsable(let expected):
                return "Expected \(expected)."
            case .outOfRange(let lowest, let highest):
                return "Must be between \(lowest) and \(highest)."
            case .tooLong(let limit):
                return "At most \(limit) characters fit."
            }
        }
    }

    public init?(_ node: DecodedPattern, bytes: ArraySlice<UInt8>) {
        guard node.children.isEmpty, let value = node.value, let size = node.size, size > 0, bytes.count == size else { return nil }
        let container = Array(bytes)
        let bits = node.bits > 0 ? (first: node.bitOffset! % 8, count: node.bits) : nil
        let declared = Self.declaredOrder(of: node.typeName)
        guard let layout = Self.layout(of: value, in: container, bits: bits, typeName: node.typeName, declared: declared) else {
            return nil
        }
        address = node.address
        text = Self.text(of: value)
        self.container = container
        self.layout = layout
    }

    public func bytes(parsing text: String) throws -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch layout {
        case .number(let scalar, let order):
            let value = try Self.parse(trimmed, as: scalar, bitWidth: container.count * 8)
            return Self.integerBytes(value, width: container.count, order: order)
        case .bits(let scalar, let first, let count, let order):
            let value = try Self.parse(trimmed, as: scalar, bitWidth: count)
            return Self.settingBits(of: container, first: first, count: count, to: value, order: order)
        case .floating(let order):
            guard let number = Double(trimmed) else { throw Problem.unparsable(expected: "a number") }
            return Self.floatingBytes(number, width: container.count, order: order)
        case .characters(let unit, let order):
            return try Self.characterBytes(text, unit: unit, count: container.count / unit, order: order)
        }
    }

    private static func declaredOrder(of typeName: String) -> ByteOrder? {
        if typeName.hasPrefix("le ") {
            return .little
        }
        if typeName.hasPrefix("be ") {
            return .big
        }
        return nil
    }

    private static func layout(
        of value: DecodedScalar, in container: [UInt8], bits: (first: Int, count: Int)?, typeName: String, declared: ByteOrder?
    ) -> Layout? {
        let candidates = declared.map { [$0] } ?? ByteOrder.allCases
        switch value {
        case .integer, .unsigned, .boolean:
            let scalar = scalar(of: value)
            if let bits {
                let current = pattern(of: value, bitWidth: bits.count)
                return candidates.first { extractedBits(of: container, first: bits.first, count: bits.count, order: $0) == current }
                    .map { .bits(scalar, first: bits.first, count: bits.count, $0) }
            }
            guard (1...8).contains(container.count) else { return nil }
            let current = pattern(of: value, bitWidth: container.count * 8)
            return candidates.first { integerBytes(current, width: container.count, order: $0) == container }
                .map { .number(scalar, $0) }
        case .floating(let number):
            guard container.count == 4 || container.count == 8 else { return nil }
            return candidates.first { floatingBytes(number, width: container.count, order: $0) == container }
                .map { .floating($0) }
        case .string(let text):
            let unit = typeName.contains("char16") ? 2 : 1
            guard container.count % unit == 0 else { return nil }
            let count = container.count / unit
            let matching = candidates.first { (try? characterBytes(text, unit: unit, count: count, order: $0)) == container }
            return .characters(unit: unit, matching ?? candidates[0])
        }
    }

    private static func scalar(of value: DecodedScalar) -> Scalar {
        switch value {
        case .integer:
            return .signed
        case .boolean:
            return .boolean
        default:
            return .unsigned
        }
    }

    private static func pattern(of value: DecodedScalar, bitWidth: Int) -> UInt64 {
        switch value {
        case .integer(let number):
            return UInt64(bitPattern: number) & mask(bitWidth)
        case .unsigned(let number):
            return number
        case .boolean(let flag):
            return flag ? 1 : 0
        default:
            return 0
        }
    }

    private static func text(of value: DecodedScalar) -> String {
        switch value {
        case .string(let text):
            return text
        default:
            return value.description
        }
    }

    private static func parse(_ text: String, as scalar: Scalar, bitWidth: Int) throws -> UInt64 {
        switch scalar {
        case .boolean:
            switch text.lowercased() {
            case "true", "1":
                return 1
            case "false", "0":
                return 0
            default:
                throw Problem.unparsable(expected: "true or false")
            }
        case .unsigned:
            guard let magnitude = parseMagnitude(text) else { throw Problem.unparsable(expected: "an unsigned integer") }
            guard magnitude <= mask(bitWidth) else {
                throw Problem.outOfRange(lowest: "0", highest: String(format: "0x%llx", mask(bitWidth)))
            }
            return magnitude
        case .signed:
            let isNegative = text.hasPrefix("-")
            guard let magnitude = parseMagnitude(isNegative ? String(text.dropFirst()) : text) else {
                throw Problem.unparsable(expected: "an integer")
            }
            let limit = UInt64(1) << UInt64(bitWidth - 1)
            guard magnitude <= (isNegative ? limit : limit - 1) else {
                throw Problem.outOfRange(lowest: "-\(limit)", highest: String(limit - 1))
            }
            return (isNegative ? 0 &- magnitude : magnitude) & mask(bitWidth)
        }
    }

    private static func parseMagnitude(_ text: String) -> UInt64? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x") {
            return UInt64(lowered.dropFirst(2), radix: 16)
        }
        if lowered.hasPrefix("0b") {
            return UInt64(lowered.dropFirst(2), radix: 2)
        }
        return UInt64(lowered, radix: 10)
    }

    private static func integerBytes(_ value: UInt64, width: Int, order: ByteOrder) -> [UInt8] {
        let little = (0..<width).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
        return order == .little ? little : little.reversed()
    }

    private static func floatingBytes(_ number: Double, width: Int, order: ByteOrder) -> [UInt8] {
        let pattern = width == 4 ? UInt64(Float(number).bitPattern) : number.bitPattern
        return integerBytes(pattern, width: width, order: order)
    }

    private static func characterBytes(_ text: String, unit: Int, count: Int, order: ByteOrder) throws -> [UInt8] {
        let units: [UInt64] = unit == 1 ? Array(text.utf8).map(UInt64.init) : Array(text.utf16).map(UInt64.init)
        guard units.count <= count else { throw Problem.tooLong(limit: count) }
        return (units + Array(repeating: 0, count: count - units.count)).flatMap { integerBytes($0, width: unit, order: order) }
    }

    private static func extractedBits(of container: [UInt8], first: Int, count: Int, order: ByteOrder) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count {
            let bit = UInt64(container[(first + i) / 8] >> bitShift(of: first + i, order: order)) & 1
            value |= bit << UInt64(order == .little ? i : count - 1 - i)
        }
        return value
    }

    private static func settingBits(of container: [UInt8], first: Int, count: Int, to value: UInt64, order: ByteOrder) -> [UInt8] {
        var bytes = container
        for i in 0..<count {
            let bit = UInt8((value >> UInt64(order == .little ? i : count - 1 - i)) & 1)
            let shift = bitShift(of: first + i, order: order)
            bytes[(first + i) / 8] &= ~(1 << shift)
            bytes[(first + i) / 8] |= bit << shift
        }
        return bytes
    }

    private static func bitShift(of index: Int, order: ByteOrder) -> UInt8 {
        UInt8(order == .little ? index % 8 : 7 - index % 8)
    }

    private static func mask(_ bitWidth: Int) -> UInt64 {
        bitWidth == 64 ? .max : (UInt64(1) << UInt64(bitWidth)) - 1
    }
}
