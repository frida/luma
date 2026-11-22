import Foundation

public enum FeatureSchema: Sendable, Equatable {
    case boolean(default: Bool)
    case int(default: Int64, min: Int64?, max: Int64?)
    case uint(default: UInt64, min: UInt64?, max: UInt64?)
    case double(default: Double, min: Double?, max: Double?)
    case string(default: String)
    case regex(default: String)
    case combo(choices: [ComboChoice], default: String?)
    case object(fields: [ObjectField])
    case array(item: ArrayItemSchema, default: [FeatureValue])

    public var defaultValue: FeatureValue {
        switch self {
        case .boolean(let d): return .boolean(d)
        case .int(let d, _, _): return .int(d)
        case .uint(let d, _, _): return .uint(d)
        case .double(let d, _, _): return .double(d)
        case .string(let d): return .string(d)
        case .regex(let d): return .regex(d)
        case .combo(let choices, let d): return .string(d ?? choices.first?.id ?? "")
        case .object(let fields):
            let entries = fields.compactMap { field -> (String, FeatureValue)? in
                guard !field.optional || field.enabledByDefault else { return nil }
                return (field.id, field.schema.defaultValue)
            }
            return .object(Dictionary(uniqueKeysWithValues: entries))
        case .array(_, let d): return .array(d)
        }
    }
}

public struct ComboChoice: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ObjectField: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var schema: FeatureSchema
    public var optional: Bool
    public var enabledByDefault: Bool

    public init(
        id: String,
        name: String,
        schema: FeatureSchema,
        optional: Bool = false,
        enabledByDefault: Bool = true
    ) {
        self.id = id
        self.name = name
        self.schema = schema
        self.optional = optional
        self.enabledByDefault = enabledByDefault
    }
}

public enum ArrayItemSchema: Sendable, Equatable {
    case boolean
    case int
    case uint
    case double
    case string
    case regex
    case combo(choices: [ComboChoice])
    case object(fields: [ObjectField])

    public var defaultValue: FeatureValue {
        switch self {
        case .boolean: return .boolean(false)
        case .int: return .int(0)
        case .uint: return .uint(0)
        case .double: return .double(0)
        case .string: return .string("")
        case .regex: return .regex("")
        case .combo(let choices): return .string(choices.first?.id ?? "")
        case .object(let fields):
            let entries = fields.compactMap { field -> (String, FeatureValue)? in
                guard !field.optional || field.enabledByDefault else { return nil }
                return (field.id, field.schema.defaultValue)
            }
            return .object(Dictionary(uniqueKeysWithValues: entries))
        }
    }

    public var asFeatureSchema: FeatureSchema {
        switch self {
        case .boolean: return .boolean(default: false)
        case .int: return .int(default: 0, min: nil, max: nil)
        case .uint: return .uint(default: 0, min: nil, max: nil)
        case .double: return .double(default: 0, min: nil, max: nil)
        case .string: return .string(default: "")
        case .regex: return .regex(default: "")
        case .combo(let choices): return .combo(choices: choices, default: nil)
        case .object(let fields): return .object(fields: fields)
        }
    }
}

extension ObjectField {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            schema: try c.decode(FeatureSchema.self, forKey: .schema),
            optional: try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false,
            enabledByDefault: try c.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true)
    }
}

extension FeatureSchema: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case `default`
        case min
        case max
        case choices
        case item
        case fields
    }

    private enum Kind: String, Codable {
        case boolean
        case int
        case uint
        case double
        case string
        case regex
        case combo
        case object
        case array
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .boolean:
            self = .boolean(default: try c.decodeIfPresent(Bool.self, forKey: .default) ?? false)
        case .int:
            self = .int(
                default: try c.decode(Int64.self, forKey: .default),
                min: try c.decodeIfPresent(Int64.self, forKey: .min),
                max: try c.decodeIfPresent(Int64.self, forKey: .max)
            )
        case .uint:
            self = .uint(
                default: try c.decode(UInt64.self, forKey: .default),
                min: try c.decodeIfPresent(UInt64.self, forKey: .min),
                max: try c.decodeIfPresent(UInt64.self, forKey: .max)
            )
        case .double:
            self = .double(
                default: try c.decode(Double.self, forKey: .default),
                min: try c.decodeIfPresent(Double.self, forKey: .min),
                max: try c.decodeIfPresent(Double.self, forKey: .max)
            )
        case .string:
            self = .string(default: try c.decode(String.self, forKey: .default))
        case .regex:
            self = .regex(default: try c.decode(String.self, forKey: .default))
        case .combo:
            let choices = try c.decode([ComboChoice].self, forKey: .choices)
            self = .combo(choices: choices, default: try Self.decodeComboDefault(from: c, among: choices))
        case .object:
            self = .object(fields: try c.decode([ObjectField].self, forKey: .fields))
        case .array:
            let item = try c.decode(ArrayItemSchema.self, forKey: .item)
            self = .array(item: item, default: try Self.decodeArrayDefault(from: c, of: item))
        }
    }

    private static func decodeComboDefault(from c: KeyedDecodingContainer<CodingKeys>, among choices: [ComboChoice]) throws -> String? {
        guard let d = try c.decodeIfPresent(String.self, forKey: .default) else { return nil }
        guard choices.contains(where: { $0.id == d }) else {
            throw DecodingError.dataCorruptedError(forKey: .default, in: c, debugDescription: "'\(d)' is none of the choices")
        }
        return d
    }

    private static func decodeArrayDefault(from c: KeyedDecodingContainer<CodingKeys>, of item: ArrayItemSchema) throws -> [FeatureValue] {
        var elements = try c.nestedUnkeyedContainer(forKey: .default)
        var values: [FeatureValue] = []
        while !elements.isAtEnd {
            let element = try elements.superDecoder()
            let value = try FeatureValue(from: element)
            guard value.matches(schema: item) else {
                throw DecodingError.dataCorrupted(.init(codingPath: element.codingPath, debugDescription: "does not match the item schema"))
            }
            if case .combo(let choices) = item, case .string(let id) = value, !choices.contains(where: { $0.id == id }) {
                throw DecodingError.dataCorrupted(.init(codingPath: element.codingPath, debugDescription: "'\(id)' is none of the choices"))
            }
            values.append(value)
        }
        return values
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let d):
            try c.encode(Kind.boolean, forKey: .kind)
            try c.encode(d, forKey: .default)
        case .int(let d, let lo, let hi):
            try c.encode(Kind.int, forKey: .kind)
            try c.encode(d, forKey: .default)
            try c.encodeIfPresent(lo, forKey: .min)
            try c.encodeIfPresent(hi, forKey: .max)
        case .uint(let d, let lo, let hi):
            try c.encode(Kind.uint, forKey: .kind)
            try c.encode(d, forKey: .default)
            try c.encodeIfPresent(lo, forKey: .min)
            try c.encodeIfPresent(hi, forKey: .max)
        case .double(let d, let lo, let hi):
            try c.encode(Kind.double, forKey: .kind)
            try c.encode(d, forKey: .default)
            try c.encodeIfPresent(lo, forKey: .min)
            try c.encodeIfPresent(hi, forKey: .max)
        case .string(let d):
            try c.encode(Kind.string, forKey: .kind)
            try c.encode(d, forKey: .default)
        case .regex(let d):
            try c.encode(Kind.regex, forKey: .kind)
            try c.encode(d, forKey: .default)
        case .combo(let choices, let d):
            try c.encode(Kind.combo, forKey: .kind)
            try c.encode(choices, forKey: .choices)
            try c.encodeIfPresent(d, forKey: .default)
        case .object(let fields):
            try c.encode(Kind.object, forKey: .kind)
            try c.encode(fields, forKey: .fields)
        case .array(let item, let d):
            try c.encode(Kind.array, forKey: .kind)
            try c.encode(item, forKey: .item)
            try c.encode(d, forKey: .default)
        }
    }
}

extension ArrayItemSchema: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case choices
        case fields
    }

    private enum Kind: String, Codable {
        case boolean
        case int
        case uint
        case double
        case string
        case regex
        case combo
        case object
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .boolean: self = .boolean
        case .int: self = .int
        case .uint: self = .uint
        case .double: self = .double
        case .string: self = .string
        case .regex: self = .regex
        case .combo: self = .combo(choices: try c.decode([ComboChoice].self, forKey: .choices))
        case .object: self = .object(fields: try c.decode([ObjectField].self, forKey: .fields))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean: try c.encode(Kind.boolean, forKey: .kind)
        case .int: try c.encode(Kind.int, forKey: .kind)
        case .uint: try c.encode(Kind.uint, forKey: .kind)
        case .double: try c.encode(Kind.double, forKey: .kind)
        case .string: try c.encode(Kind.string, forKey: .kind)
        case .regex: try c.encode(Kind.regex, forKey: .kind)
        case .combo(let choices):
            try c.encode(Kind.combo, forKey: .kind)
            try c.encode(choices, forKey: .choices)
        case .object(let fields):
            try c.encode(Kind.object, forKey: .kind)
            try c.encode(fields, forKey: .fields)
        }
    }
}
