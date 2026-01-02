import Foundation
import Frida

enum JSInspectValue: nonisolated Codable, nonisolated Equatable {
    case number(Double)
    case string(String)
    case object(id: Int, properties: [Property])
    case array(id: Int, elements: [JSInspectValue])
    case nativePointer(String)
    case null
    case boolean(Bool)
    case bytes(Bytes)
    case function(String)
    case error(name: String, message: String, stack: String)
    case undefined
    case bigInt(String)
    case symbol(String)
    case date(String)
    case regExp(pattern: String, flags: String)
    case map(id: Int, entries: [Property])
    case set(id: Int, elements: [JSInspectValue])
    case promise
    case weakMap
    case weakSet
    case depthLimit(container: ContainerKind)
    case circular(id: Int)

    struct Property: nonisolated Codable, nonisolated Equatable {
        let key: JSInspectValue
        let value: JSInspectValue

        nonisolated init(key: JSInspectValue, value: JSInspectValue) {
            self.key = key
            self.value = value
        }

        nonisolated init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            let key = try container.decode(JSInspectValue.self)
            let value = try container.decode(JSInspectValue.self)
            self.init(key: key, value: value)
        }

        nonisolated func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(key)
            try container.encode(value)
        }
    }

    struct Bytes: nonisolated Equatable {
        let data: Data
        let kind: BytesKind

        nonisolated init(data: Data, kind: BytesKind) {
            self.data = data
            self.kind = kind
        }
    }

    enum BytesKind: String, nonisolated Codable, nonisolated Equatable {
        case arrayBuffer = "ArrayBuffer"
        case dataView = "DataView"

        case int8Array = "Int8Array"
        case uint8Array = "Uint8Array"
        case uint8ClampedArray = "Uint8ClampedArray"
        case int16Array = "Int16Array"
        case uint16Array = "Uint16Array"
        case int32Array = "Int32Array"
        case uint32Array = "Uint32Array"
        case float32Array = "Float32Array"
        case float64Array = "Float64Array"
        case bigInt64Array = "BigInt64Array"
        case bigUint64Array = "BigUint64Array"
    }

    enum ContainerKind: nonisolated Equatable {
        case object
        case array
        case map
        case set
    }

    private enum Kind: Int {
        case number = 0
        case string = 1
        case object = 2
        case array = 3
        case nativePointer = 4
        case null = 5
        case boolean = 6
        case bytes = 7
        case function = 8
        case error = 9
        case undefined = 10
        case bigInt = 11
        case symbol = 12
        case date = 13
        case regExp = 14
        case map = 15
        case set = 16
        case promise = 17
        case weakMap = 18
        case weakSet = 19
        case depthLimit = 20
        case circular = 21
    }

    nonisolated init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let rawKind = try container.decode(Int.self)

        guard let kind = Kind(rawValue: rawKind) else {
            throw Error.invalidArgument("Invalid kind")
        }

        switch kind {
        case .number:
            self = .number(try container.decode(Double.self))

        case .string:
            self = .string(try container.decode(String.self))

        case .object:
            if container.isAtEnd {
                self = .object(id: 0, properties: [])
            } else {
                let id = try container.decode(Int.self)
                let props = try container.decode([Property].self)
                self = .object(id: id, properties: props)
            }

        case .array:
            if container.isAtEnd {
                self = .array(id: 0, elements: [])
            } else {
                let id = try container.decode(Int.self)
                let elements = try container.decode([JSInspectValue].self)
                self = .array(id: id, elements: elements)
            }

        case .nativePointer:
            self = .nativePointer(try container.decode(String.self))

        case .null:
            self = .null

        case .boolean:
            self = .boolean(try container.decode(Bool.self))

        case .bytes:
            let data = try container.decode(Data.self)
            let kind = try container.decode(BytesKind.self)
            self = .bytes(Bytes(data: data, kind: kind))

        case .function:
            self = .function(try container.decode(String.self))

        case .error:
            let name = try container.decode(String.self)
            let message = try container.decode(String.self)
            let stack = try container.decode(String.self)
            self = .error(name: name, message: message, stack: stack)

        case .undefined:
            self = .undefined

        case .bigInt:
            self = .bigInt(try container.decode(String.self))

        case .symbol:
            self = .symbol(try container.decode(String.self))

        case .date:
            self = .date(try container.decode(String.self))

        case .regExp:
            let pattern = try container.decode(String.self)
            let flags = try container.decode(String.self)
            self = .regExp(pattern: pattern, flags: flags)

        case .map:
            if container.isAtEnd {
                self = .map(id: 0, entries: [])
            } else {
                let id = try container.decode(Int.self)
                let entries = try container.decode([Property].self)
                self = .map(id: id, entries: entries)
            }

        case .set:
            if container.isAtEnd {
                self = .set(id: 0, elements: [])
            } else {
                let id = try container.decode(Int.self)
                let elements = try container.decode([JSInspectValue].self)
                self = .set(id: id, elements: elements)
            }

        case .promise:
            self = .promise

        case .weakMap:
            self = .weakMap

        case .weakSet:
            self = .weakSet

        case .depthLimit:
            let containerTag = try container.decode(Int.self)
            let containerKind: ContainerKind
            switch containerTag {
            case Kind.object.rawValue:
                containerKind = .object
            case Kind.array.rawValue:
                containerKind = .array
            case Kind.map.rawValue:
                containerKind = .map
            case Kind.set.rawValue:
                containerKind = .set
            default:
                containerKind = .object
            }
            self = .depthLimit(container: containerKind)

        case .circular:
            let id = try container.decode(Int.self)
            self = .circular(id: id)
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()

        switch self {
        case .number(let n):
            try container.encode(Kind.number.rawValue)
            try container.encode(n)

        case .string(let s):
            try container.encode(Kind.string.rawValue)
            try container.encode(s)

        case .object(let id, let props):
            try container.encode(Kind.object.rawValue)
            try container.encode(id)
            try container.encode(props)

        case .array(let id, let elements):
            try container.encode(Kind.array.rawValue)
            try container.encode(id)
            try container.encode(elements)

        case .nativePointer(let s):
            try container.encode(Kind.nativePointer.rawValue)
            try container.encode(s)

        case .null:
            try container.encode(Kind.null.rawValue)

        case .boolean(let b):
            try container.encode(Kind.boolean.rawValue)
            try container.encode(b)

        case .bytes(let bytes):
            try container.encode(Kind.bytes.rawValue)
            try container.encode(bytes.data)
            try container.encode(bytes.kind)

        case .function(let t):
            try container.encode(Kind.function.rawValue)
            try container.encode(t)

        case .error(let name, let message, let stack):
            try container.encode(Kind.error.rawValue)
            try container.encode(name)
            try container.encode(message)
            try container.encode(stack)

        case .undefined:
            try container.encode(Kind.undefined.rawValue)

        case .bigInt(let s):
            try container.encode(Kind.bigInt.rawValue)
            try container.encode(s)

        case .symbol(let t):
            try container.encode(Kind.symbol.rawValue)
            try container.encode(t)

        case .date(let s):
            try container.encode(Kind.date.rawValue)
            try container.encode(s)

        case .regExp(let pattern, let flags):
            try container.encode(Kind.regExp.rawValue)
            try container.encode(pattern)
            try container.encode(flags)

        case .map(let id, let entries):
            try container.encode(Kind.map.rawValue)
            try container.encode(id)
            try container.encode(entries)

        case .set(let id, let elements):
            try container.encode(Kind.set.rawValue)
            try container.encode(id)
            try container.encode(elements)

        case .promise:
            try container.encode(Kind.promise.rawValue)

        case .weakMap:
            try container.encode(Kind.weakMap.rawValue)

        case .weakSet:
            try container.encode(Kind.weakSet.rawValue)

        case .depthLimit(let containerKind):
            try container.encode(Kind.depthLimit.rawValue)
            let tag: Int
            switch containerKind {
            case .object:
                tag = Kind.object.rawValue
            case .array:
                tag = Kind.array.rawValue
            case .map:
                tag = Kind.map.rawValue
            case .set:
                tag = Kind.set.rawValue
            }
            try container.encode(tag)

        case .circular(let id):
            try container.encode(Kind.circular.rawValue)
            try container.encode(id)
        }
    }

    var nativePointerAddress: UInt64? {
        guard case .nativePointer(let s) = self else { return nil }
        return UInt64(s.dropFirst(2), radix: 16)
    }
}

extension JSInspectValue {
    enum DecodePackedError: Swift.Error {
        case invalidRoot
        case invalidBlob
        case invalidNode
        case invalidTag(Int)
        case invalidBytesRange
    }

    nonisolated static func decodePacked(from root: Any) throws -> JSInspectValue {
        guard let pair = root as? [Any], pair.count == 2 else {
            throw DecodePackedError.invalidRoot
        }

        let tree = pair[0]

        let blobData: Data
        let blobCandidate = pair[1]
        if let bytes = blobCandidate as? [UInt8] {
            blobData = Data(bytes)
        } else if let d = blobCandidate as? Data {
            blobData = d
        } else if blobCandidate is NSNull {
            blobData = Data()
        } else {
            throw DecodePackedError.invalidBlob
        }

        return try decodePacked(tree: tree, blobData: blobData)
    }

    nonisolated static func decodePacked(tree: Any, blobBytes: [UInt8]?) throws -> JSInspectValue {
        return try decodePacked(tree: tree, blobData: Data(blobBytes ?? []))
    }

    nonisolated static func decodePacked(tree: Any, blobData: Data) throws -> JSInspectValue {
        func intFrom(_ any: Any) throws -> Int {
            if let i = any as? Int { return i }
            if let n = any as? NSNumber { return n.intValue }
            throw DecodePackedError.invalidNode
        }

        func doubleFrom(_ any: Any) throws -> Double {
            if let d = any as? Double { return d }
            if let n = any as? NSNumber { return n.doubleValue }
            throw DecodePackedError.invalidNode
        }

        func boolFrom(_ any: Any) throws -> Bool {
            if let b = any as? Bool { return b }
            if let n = any as? NSNumber { return n.boolValue }
            throw DecodePackedError.invalidNode
        }

        func stringFrom(_ any: Any) throws -> String {
            if let s = any as? String { return s }
            throw DecodePackedError.invalidNode
        }

        func decodeNode(_ node: Any) throws -> JSInspectValue {
            guard let arr = node as? [Any], !arr.isEmpty else {
                throw DecodePackedError.invalidNode
            }

            let rawTagAny = arr[0]
            let rawTag = try intFrom(rawTagAny)
            guard let kind = Kind(rawValue: rawTag) else {
                throw DecodePackedError.invalidTag(rawTag)
            }

            switch kind {
            case .number:
                let value = try doubleFrom(arr[1])
                return .number(value)

            case .string:
                let s = try stringFrom(arr[1])
                return .string(s)

            case .object:
                let id = try intFrom(arr[1])
                let rawEntries = (arr.count > 2 ? arr[2] : []) as? [Any] ?? []
                let properties: [Property] = try rawEntries.map { entryAny in
                    guard let entry = entryAny as? [Any], entry.count == 2 else {
                        throw DecodePackedError.invalidNode
                    }
                    let key = try decodeNode(entry[0])
                    let value = try decodeNode(entry[1])
                    return Property(key: key, value: value)
                }
                return .object(id: id, properties: properties)

            case .array:
                let id = try intFrom(arr[1])
                let rawElements = (arr.count > 2 ? arr[2] : []) as? [Any] ?? []
                let elements: [JSInspectValue] = try rawElements.map { try decodeNode($0) }
                return .array(id: id, elements: elements)

            case .nativePointer:
                let s = try stringFrom(arr[1])
                return .nativePointer(s)

            case .null:
                return .null

            case .boolean:
                let b = try boolFrom(arr[1])
                return .boolean(b)

            case .bytes:
                let offset = try intFrom(arr[1])
                let length = try intFrom(arr[2])
                let kindRaw = try stringFrom(arr[3])
                let kind = BytesKind(rawValue: kindRaw) ?? .arrayBuffer

                let start = offset
                let end = offset + length
                guard start >= 0, length >= 0, end <= blobData.count else {
                    throw DecodePackedError.invalidBytesRange
                }

                let slice = blobData.subdata(in: start..<end)
                return .bytes(Bytes(data: slice, kind: kind))

            case .function:
                let sig = try stringFrom(arr[1])
                return .function(sig)

            case .error:
                let name = try stringFrom(arr[1])
                let message = try stringFrom(arr[2])
                let stack = try stringFrom(arr[3])
                return .error(name: name, message: message, stack: stack)

            case .undefined:
                return .undefined

            case .bigInt:
                let s = try stringFrom(arr[1])
                return .bigInt(s)

            case .symbol:
                let s = try stringFrom(arr[1])
                return .symbol(s)

            case .date:
                let s = try stringFrom(arr[1])
                return .date(s)

            case .regExp:
                let pattern = try stringFrom(arr[1])
                let flags = try stringFrom(arr[2])
                return .regExp(pattern: pattern, flags: flags)

            case .map:
                let id = try intFrom(arr[1])
                let rawEntries = (arr.count > 2 ? arr[2] : []) as? [Any] ?? []
                let entries: [Property] = try rawEntries.map { entryAny in
                    guard let entry = entryAny as? [Any], entry.count == 2 else {
                        throw DecodePackedError.invalidNode
                    }
                    let key = try decodeNode(entry[0])
                    let value = try decodeNode(entry[1])
                    return Property(key: key, value: value)
                }
                return .map(id: id, entries: entries)

            case .set:
                let id = try intFrom(arr[1])
                let rawElements = (arr.count > 2 ? arr[2] : []) as? [Any] ?? []
                let elements: [JSInspectValue] = try rawElements.map { try decodeNode($0) }
                return .set(id: id, elements: elements)

            case .promise:
                return .promise

            case .weakMap:
                return .weakMap

            case .weakSet:
                return .weakSet

            case .depthLimit:
                let containerTag = try intFrom(arr[1])
                let containerKind: ContainerKind
                switch containerTag {
                case Kind.object.rawValue:
                    containerKind = .object
                case Kind.array.rawValue:
                    containerKind = .array
                case Kind.map.rawValue:
                    containerKind = .map
                case Kind.set.rawValue:
                    containerKind = .set
                default:
                    containerKind = .object
                }
                return .depthLimit(container: containerKind)

            case .circular:
                let id = try intFrom(arr[1])
                return .circular(id: id)
            }
        }

        return try decodeNode(tree)
    }
}
