import Foundation

public enum FeatureValue: Sendable, Equatable {
    case boolean(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case regex(String)
    case object([String: FeatureValue])
    case array([FeatureValue])

    public func reconciled(with schema: FeatureSchema) -> FeatureValue {
        switch (self, schema) {
        case (.object(let values), .object(let fields)):
            return .object(FeatureValue.reconciled(values, with: fields))
        case (.array(let items), .array(let item, _)):
            return .array(items.map { $0.reconciled(with: item.asFeatureSchema) })
        default:
            return matches(schema: schema) ? self : schema.defaultValue
        }
    }

    private static func reconciled(_ values: [String: FeatureValue], with fields: [ObjectField]) -> [String: FeatureValue] {
        var kept: [String: FeatureValue] = [:]
        for field in fields {
            if let value = values[field.id] {
                kept[field.id] = value.reconciled(with: field.schema)
            } else if !field.optional {
                kept[field.id] = field.schema.defaultValue
            }
        }
        return kept
    }

    public func matches(schema: FeatureSchema) -> Bool {
        switch (self, schema) {
        case (.boolean, .boolean): return true
        case (.int, .int): return true
        case (.uint, .uint): return true
        case (.double, .double): return true
        case (.string, .string), (.string, .combo): return true
        case (.regex, .regex): return true
        case (.object(let valueFields), .object(let schemaFields)):
            return FeatureValue.objectFieldsMatch(valueFields: valueFields, schemaFields: schemaFields)
        case (.array(let items), .array(let item, _)):
            return items.allSatisfy { $0.matches(schema: item) }
        default:
            return false
        }
    }

    public func matches(schema: ArrayItemSchema) -> Bool {
        switch (self, schema) {
        case (.boolean, .boolean): return true
        case (.int, .int): return true
        case (.uint, .uint): return true
        case (.double, .double): return true
        case (.string, .string), (.string, .combo): return true
        case (.regex, .regex): return true
        case (.object(let valueFields), .object(let schemaFields)):
            return FeatureValue.objectFieldsMatch(valueFields: valueFields, schemaFields: schemaFields)
        default:
            return false
        }
    }

    private static func objectFieldsMatch(
        valueFields: [String: FeatureValue],
        schemaFields: [ObjectField]
    ) -> Bool {
        let knownIDs = Set(schemaFields.map(\.id))
        for id in valueFields.keys where !knownIDs.contains(id) {
            return false
        }
        for field in schemaFields {
            if let v = valueFields[field.id] {
                if !v.matches(schema: field.schema) { return false }
            } else if !field.optional {
                return false
            }
        }
        return true
    }

    public func toJSONNative() -> Any {
        switch self {
        case .boolean(let v): return v
        case .int(let v): return NSNumber(value: v)
        case .uint(let v): return NSNumber(value: v)
        case .double(let v): return NSNumber(value: v)
        case .string(let v): return v
        case .regex(let v): return v
        case .object(let fields): return fields.mapValues { $0.toJSONNative() }
        case .array(let items): return items.map { $0.toJSONNative() }
        }
    }
}

extension FeatureValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case boolean
        case int
        case uint
        case double
        case string
        case regex
        case object
        case array
    }

    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .boolean: self = .boolean(try c.decode(Bool.self, forKey: .value))
        case .int: self = .int(try c.decode(Int64.self, forKey: .value))
        case .uint: self = .uint(try c.decode(UInt64.self, forKey: .value))
        case .double: self = .double(try c.decode(Double.self, forKey: .value))
        case .string: self = .string(try c.decode(String.self, forKey: .value))
        case .regex: self = .regex(try c.decode(String.self, forKey: .value))
        case .object: self = .object(try c.decode([String: FeatureValue].self, forKey: .value))
        case .array: self = .array(try c.decode([FeatureValue].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let v):
            try c.encode(Kind.boolean, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .int(let v):
            try c.encode(Kind.int, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .uint(let v):
            try c.encode(Kind.uint, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .double(let v):
            try c.encode(Kind.double, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .string(let v):
            try c.encode(Kind.string, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .regex(let v):
            try c.encode(Kind.regex, forKey: .kind)
            try c.encode(v, forKey: .value)
        case .object(let fields):
            try c.encode(Kind.object, forKey: .kind)
            try c.encode(fields, forKey: .value)
        case .array(let items):
            try c.encode(Kind.array, forKey: .kind)
            try c.encode(items, forKey: .value)
        }
    }
}
